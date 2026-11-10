import Foundation
import CoreFoundation

struct DemandChatDiscovery {
    var groups: [DemandChat]
    var restrictedIDs: Set<String> = []
}

struct DemandChatDirectoryCache: Codable {
    let groups: [DemandChat]
    let restrictedIDs: Set<String>
}

/// Content search may find groups that the current organization's group directory omits.
/// Only read conversation metadata, and verify group identity before adding a candidate.
enum DemandChatDiscoveryService {
    static func candidates(_ data: Data, query: String) throws -> [DemandChat] {
        guard BusinessResponse.succeeded(data),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["result"] as? [[String: Any]] else { throw DemandChatDirectoryError.unreadable }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard row["sourceType"] as? String == "im", let meta = row["meta"] as? [String: Any],
                  let name = meta["conversation_title"] as? String,
                  let id = (row["openConversationId"] as? String) ?? (meta["openConversationId"] as? String) else { return nil }
            let chat = DemandChat(id: id, name: name)
            guard chat.isValid, DemandChatSearch.matches(chat, query: query), seen.insert(id).inserted else { return nil }
            return chat
        }
    }

    static func verified(_ result: CommandResult, candidate: DemandChat) -> DemandChatDiscovery? {
        guard !result.timedOut, result.outputComplete else { return nil }
        if result.businessSucceeded,
           let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
           let body = root["result"] as? [String: Any], let info = body["conversationInfo"] as? [String: Any],
           let single = info["singleChat"] as? NSNumber, CFGetTypeID(single) == CFBooleanGetTypeID(),
           !single.boolValue, let id = info["openConversationId"] as? String, id == candidate.id,
           let name = info["title"] as? String {
            let chat = DemandChat(id: id, name: name)
            return chat.isValid ? DemandChatDiscovery(groups: [chat]) : nil
        }
        // This specific denial confirms an internal group, but grants no message access.
        for bytes in [result.stderr, result.stdout] {
            guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let error = root["error"] as? [String: Any],
                  error["server_error_code"] as? String == "FORBIDDEN",
                  (error["message"] as? String)?.contains("无权访问该内部群") == true else { continue }
            return DemandChatDiscovery(groups: [candidate], restrictedIDs: [candidate.id])
        }
        return nil
    }

    static func confirmingMessageAccess(_ discovery: DemandChatDiscovery, for id: String,
                                        result: CommandResult) -> DemandChatDiscovery {
        guard result.businessSucceeded,
              discovery.groups.contains(where: { $0.id == id }),
              let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let body = root["result"] as? [String: Any],
              body["messages"] is [[String: Any]],
              let more = body["hasMore"] as? NSNumber, CFGetTypeID(more) == CFBooleanGetTypeID() else { return discovery }
        var confirmed = discovery
        confirmed.restrictedIDs.remove(id)
        return confirmed
    }

    static func discover(_ query: String) async throws -> DemandChatDiscovery {
        let found = await command(["aisearch", "enterprise", "--queries", query, "--types", "im",
                                   "--fields", "sourceType,meta,openConversationId"])
        guard found.succeeded else { throw DemandChatDirectoryError.unavailable }
        let candidates = try candidates(found.stdout, query: query)
        try Task.checkCancellation()
        return await withTaskGroup(of: DemandChatDiscovery?.self) { tasks in
            for chat in candidates.prefix(5) {
                tasks.addTask {
                    let result = await command(["chat", "conversation-info", "--group", chat.id])
                    guard !Task.isCancelled, var discovered = verified(result, candidate: chat) else { return nil }
                    if discovered.restrictedIDs.contains(chat.id) {
                        // Group details and message reads may use different authorization checks.
                        // Probe one message with content removed; this does not change authorization.
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                        let probe = await command(["chat", "message", "list", "--group", chat.id,
                                                   "--time", formatter.string(from: Date()), "--direction", "older",
                                                   "--limit", "1", "--fields", "hasMore"])
                        guard !Task.isCancelled else { return nil }
                        discovered = confirmingMessageAccess(discovered, for: chat.id, result: probe)
                    }
                    return discovered
                }
            }
            var combined = DemandChatDiscovery(groups: [])
            for await result in tasks {
                if let result {
                    combined.groups += result.groups
                    combined.restrictedIDs.formUnion(result.restrictedIDs)
                }
            }
            return combined
        }
    }

    private static func command(_ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            ProcessRunner.run(NSHomeDirectory() + "/.qoderwork/bin/dws",
                arguments: arguments + ["--format", "json", "--timeout", "20"],
                environment: ProcessInfo.processInfo.environment, timeout: 25)
        }.value
    }
}
