import Foundation
import CoreFoundation
import Darwin

struct CommandResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
    let outputComplete: Bool
    var succeeded: Bool { exitCode == 0 && !timedOut && outputComplete }
    var businessSucceeded: Bool { succeeded && BusinessResponse.succeeded(stdout) }
}

enum BusinessResponse {
    /// 只认顶层布尔 success == true；CLI 若在 JSON 前后打印提示，只取首个 { 到末个 } 的对象。
    static func succeeded(_ data: Data) -> Bool {
        var candidates = [data]
        if let text = String(data: data, encoding: .utf8),
           let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            candidates.append(Data(text[start...end].utf8))
        }
        for candidate in candidates {
            guard let object = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any] else { continue }
            guard let flag = object["success"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
            return flag.boolValue
        }
        return false
    }
}

/// 后台调用。两条 pipe 同时持续排空，最多保留 1MB；退出码、超时和完整 JSON 分开判断。
enum ProcessRunner {
    private final class Buffer {
        let lock = NSLock()
        var data = Data()
        var truncated = false
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            let remaining = max(0, 1_048_576 - data.count)
            if chunk.count > remaining { truncated = true }
            data.append(chunk.prefix(remaining))
        }
        func snapshot() -> (Data, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (data, !truncated)
        }
    }

    static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 60) -> CommandResult {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.environment = environment
        process.standardOutput = out; process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return CommandResult(exitCode: -1, stdout: Data(), stderr: Data(), timedOut: false, outputComplete: false) }
        let group = DispatchGroup(), stdout = Buffer(), stderr = Buffer()
        for (handle, buffer) in [(out.fileHandleForReading, stdout), (err.fileHandleForReading, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close(); group.leave() }
                while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty { buffer.append(chunk) }
            }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        let drained = group.wait(timeout: .now() + 2) == .success
        let a = stdout.snapshot(), b = stderr.snapshot()
        return CommandResult(exitCode: process.isRunning ? -1 : process.terminationStatus,
            stdout: a.0, stderr: b.0, timedOut: timedOut, outputComplete: drained && a.1 && b.1)
    }
}
