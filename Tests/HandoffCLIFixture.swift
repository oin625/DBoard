import Foundation
import CryptoKit
@testable import DBoard

/// Existing business regressions explicitly request full snapshots and supply a test handoff.
enum HandoffCLIFixture {
    static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 60) -> CommandResult {
        var args = arguments
        guard let source = args.first(where: { $0.hasSuffix("/Tools/dboard_ai.py") }),
              let cacheIndex = args.firstIndex(of: "--cache"), cacheIndex + 1 < args.count else {
            return ProcessRunner.run(executable, arguments: args, environment: environment, timeout: timeout)
        }
        let cache = URL(fileURLWithPath: args[cacheIndex + 1])
        if (args.contains("show") || args.contains("context")) && !args.contains("--full") { args += ["--full"] }
        if let command = args.firstIndex(of: "report"), command + 1 < args.count, !args.contains("--compression-decision") {
            let id = args[command + 1]
            let original = args
            args += ["--compression-decision", "skip", "--compression-reason", "测试夹具：本轮增量反馈"]
            if let key = ["--summary", "--progress"].compactMap({ original.firstIndex(of: $0) }).first,
               key + 1 < original.count {
                let name = SHA256.hash(data: Data(original.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
                let file = cache.deletingLastPathComponent().appendingPathComponent("handoff-" + name + ".json")
                if !FileManager.default.fileExists(atPath: file.path) {
                    let read = ProcessRunner.run("/usr/bin/env", arguments: ["python3", source, "--cache", cache.path, "show", id, "--full"])
                    let object = (try? JSONSerialization.jsonObject(with: read.stdout)) as? [String: Any]
                    let item = object?["item"] as? [String: Any]
                    let records = item?["progress_records"] as? [[String: Any]] ?? []
                    let completed = (item?["progress"] as? String ?? "") + "\n" + original[key + 1]
                    let detail = original.firstIndex(of: "--details").map { original[$0 + 1] } ?? ""
                    let value: [String: Any] = ["based_on_records": records.count, "sections": [
                        "completed": completed, "pending": "测试夹具，待人工验收", "decisions": "", "verification": detail],
                        "references": []]
                    if let data = try? JSONSerialization.data(withJSONObject: value) { try? data.write(to: file) }
                }
                args += ["--handoff-file", file.path]
            }
        }
        return ProcessRunner.run(executable, arguments: args, environment: environment, timeout: timeout)
    }
}
