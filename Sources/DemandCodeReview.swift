import Foundation

struct DemandCodeSnapshot: Codable, Equatable {
    let path: String
    let branch: String
    let commit: String
    let dirtyHash: String
    enum CodingKeys: String, CodingKey { case path, branch, commit, dirtyHash = "dirty_hash" }
    var isValid: Bool {
        path.hasPrefix("/") && !branch.isEmpty &&
        !(path + branch).unicodeScalars.contains { $0.value < 32 } &&
        commit.range(of: #"^(?:[0-9a-f]{40}|[0-9a-f]{64})$"#, options: .regularExpression) != nil &&
        dirtyHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}

struct DemandCodeReview: Codable, Equatable {
    let id: String
    let needsReview: Bool
    let reason: String?
    enum CodingKeys: String, CodingKey { case id, needsReview = "needs_review", reason }
}

enum DemandCodeReviews {
    private struct Request: Encodable {
        let id: String
        let code: [DemandCodeSnapshot]?
        let repositories: [DemandVersion.Repository]
    }
    private struct Response: Decodable { let success: Bool; let reviews: [DemandCodeReview] }
    static var helperURL: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("CLI/dboard_code.py"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_code.py")
    }

    static func check(_ items: [DItem]) -> [DemandCodeReview] {
        let candidates = items.filter { $0.execution?.stage != .developing && $0.execution?.code != nil }
        guard !candidates.isEmpty else { return [] }
        let requests = candidates.map { Request(id: $0.id, code: $0.execution?.code, repositories: $0.executionRepositories) }
        if let bytes = try? JSONEncoder().encode(requests) {
            let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", helperURL.path, String(decoding: bytes, as: UTF8.self)],
                                           timeout: 30)
            if result.succeeded, let response = try? JSONDecoder().decode(Response.self, from: result.stdout), response.success {
                return response.reviews
            }
        }
        return candidates.map { DemandCodeReview(id: $0.id, needsReview: true, reason: "代码版本无法核实 · 需重新核验") }
    }

    static func checked(_ item: DItem) -> DItem {
        var value = item
        value.executionCodeReview = check([item]).first
        return value
    }
}

extension DBoardViewModel {
    /// Refresh on panel activation and explicit refresh, never poll repositories while idle.
    func refreshCodeReviews() {
        let token = UUID()
        codeReviewRequest = token
        let snapshot = items.filter { $0.execution?.code != nil && $0.execution?.stage != .developing && $0.status != .completed }
        for index in items.indices { items[index].executionCodeReview = nil }
        codeReviewWork?.cancel()
        guard !snapshot.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard self?.codeReviewRequest == token else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let results = DemandCodeReviews.check(snapshot)
                DispatchQueue.main.async {
                    guard let self, self.codeReviewRequest == token else { return }
                    for result in results {
                        guard let previous = snapshot.first(where: { $0.id == result.id }),
                              let index = self.items.firstIndex(where: { $0.id == result.id }),
                              self.items[index].execution == previous.execution,
                              self.items[index].executionRepositories == previous.executionRepositories else { continue }
                        self.items[index].executionCodeReview = result
                    }
                }
            }
        }
        codeReviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
