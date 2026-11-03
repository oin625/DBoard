import Foundation

/// Only the paired local client can read these short-lived, environment-specific sessions.
final class CanaryCookieBridge {
    static let shared = CanaryCookieBridge()
    static let origins = ["prod": "https://canary-tmyc.tmallyc.com",
                          "pre": "https://pre-i0-canary.tmallyc-inc.net"]
    static let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/dboard/canary-bridge-token")
    private let token: String?
    private let lock = NSLock()
    private var sessions: [String: (cookie: String, received: Date)] = [:]
    private var pairing = false
    private var lastPairAttempt = Date.distantPast

    init(token: String? = CanaryCookieBridge.loadToken()) { self.token = token }

    func pair(origin: String, approve: () -> Bool, now: Date = Date()) -> (status: String, body: Data) {
        func reply(_ status: String, _ value: [String: String]) -> (String, Data) {
            (status, (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }
        guard origin.range(of: #"^chrome-extension://[a-p]{32}$"#, options: .regularExpression) != nil,
              let token else { return reply("403 Forbidden", ["error": "Extension origin required"]) }
        lock.lock()
        guard !pairing, now.timeIntervalSince(lastPairAttempt) >= 30 else {
            lock.unlock()
            return reply("429 Too Many Requests", ["error": "Pairing pending or cooling down"])
        }
        pairing = true
        lastPairAttempt = now
        lock.unlock()
        let allowed = approve()
        lock.lock(); pairing = false; lock.unlock()
        guard allowed else { return reply("403 Forbidden", ["error": "Pairing declined"]) }
        return reply("200 OK", ["token": token])
    }

    private static func loadToken() -> String? {
        let fm = FileManager.default
        let folder = tokenURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let dir = try fm.attributesOfItem(atPath: folder.path)
            guard dir[.type] as? FileAttributeType == .typeDirectory,
                  (dir[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            if !fm.fileExists(atPath: tokenURL.path) {
                let value = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
                guard fm.createFile(atPath: tokenURL.path, contents: Data(value.utf8),
                                    attributes: [.posixPermissions: 0o600]) else { return nil }
            }
            let attrs = try fm.attributesOfItem(atPath: tokenURL.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { return nil }
            let value = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? value : nil
        } catch { return nil }
    }

    func response(method: String, path: String, origin: String, authorization: String,
                  body: Data, now: Date = Date()) -> (status: String, body: Data) {
        func reply(_ status: String, _ value: [String: String]) -> (String, Data) {
            (status, (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }
        guard let token, authorization == "Bearer " + token else {
            return reply("403 Forbidden", ["error": "Canary bridge pairing required"])
        }
        lock.lock()
        defer { lock.unlock() }
        if method == "POST", path == "/canary-cookie" {
            guard origin.range(of: #"^chrome-extension://[a-p]{32}$"#, options: .regularExpression) != nil,
                  let data = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  Set(data.keys) == Set(["environment", "origin", "cookie"]),
                  let env = data["environment"], let expected = Self.origins[env], data["origin"] == expected,
                  let cookie = data["cookie"], cookie.utf8.count <= 32768,
                  !cookie.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) else {
                return reply("400 Bad Request", ["error": "Invalid Canary session"])
            }
            sessions[env] = cookie.isEmpty ? nil : (cookie, now)
            return reply("200 OK", ["status": "ok"])
        }
        if method == "GET", path.hasPrefix("/canary-cookie/"), origin.isEmpty {
            let env = String(path.dropFirst("/canary-cookie/".count))
            guard let expected = Self.origins[env] else { return reply("404 Not Found", ["error": "Unknown environment"]) }
            guard let session = sessions[env], now.timeIntervalSince(session.received) >= 0,
                  now.timeIntervalSince(session.received) <= 90 else {
                sessions[env] = nil
                return reply("409 Conflict", ["error": "Canary session missing or stale"])
            }
            return reply("200 OK", ["origin": expected, "cookie": session.cookie])
        }
        return reply("404 Not Found", ["error": "Unsupported bridge request"])
    }
}
