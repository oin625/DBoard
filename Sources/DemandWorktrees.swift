import SwiftUI
import AppKit

struct DemandWorktreeRow: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    let branch: String
    let state: String
    let eligible: Bool
    let reason: String
    let created_by_task: Bool
    let ignored_files: Bool
}

struct DemandWorktreeSummary: Decodable {
    var registered: Int?
    var remaining: Int?
    var removed: Int?
    var error: String?
}

struct DemandWorktreeResponse: Decodable {
    struct Failure: Decodable { let message: String }
    struct Outcome: Decodable { let id: String; let removed: Bool; let reason: String }
    let success: Bool
    var error: Failure?
    var rows: [DemandWorktreeRow]?
    var summary: DemandWorktreeSummary?
    var eligible_count: Int?
    var removed_count: Int?
    var results: [Outcome]?
    var preview_revision: String?
}

/// Git inspection and cleanup always run off the UI thread, using the same CLI as execution agents.
enum DemandWorktreeCLI {
    static func arguments(cache: URL, mode: String, id: String, extra: [String] = []) -> [String] {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("CLI/dboard_ai.py")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py")
        let cli = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? source
        return ["python3", cli.path, "--cache", cache.path, "worktree", mode, id] + extra
    }

    static func run(cache: URL, mode: String, id: String, extra: [String] = []) throws -> DemandWorktreeResponse {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let result = ProcessRunner.run("/usr/bin/env", arguments: arguments(cache: cache, mode: mode, id: id, extra: extra),
                                       environment: environment, timeout: 300)
        guard result.outputComplete, !result.timedOut else {
            throw NSError(domain: "DemandWorktrees", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "操作未返回完整结果，请刷新核对台账后再重试。"])
        }
        let response = try JSONDecoder().decode(DemandWorktreeResponse.self, from: result.stdout)
        guard result.succeeded && response.success else {
            throw NSError(domain: "DemandWorktrees", code: 2, userInfo: [
                NSLocalizedDescriptionKey: response.error?.message ?? "工作树操作失败，请刷新后重试。"])
        }
        return response
    }
}

struct DemandWorktreesSection: View {
    let item: DItem
    var cacheURL = URL(fileURLWithPath: CacheFile.path)
    @State private var summary: DemandWorktreeSummary?
    @State private var showing = false
    @State private var refresh = 0

    var body: some View {
        HStack(spacing: 8) {
            Label("工作树", systemImage: "arrow.triangle.branch").font(.system(size: 12, weight: .medium))
            Text(summaryText).font(.system(size: 11)).foregroundStyle(summary?.error == nil ? Color.secondary : .orange)
            Spacer()
            Button(item.status == .completed ? "清理工作树" : "查看／登记") { showing = true }
                .controlSize(.small).accessibilityIdentifier("worktrees-open-" + item.id)
        }
        .task(id: item.id + String(refresh)) {
            summary = await Task.detached(priority: .utility) {
                do { return try DemandWorktreeCLI.run(cache: cacheURL, mode: "summary", id: item.id).summary }
                catch { return DemandWorktreeSummary(error: error.localizedDescription) }
            }.value
        }
        .sheet(isPresented: $showing, onDismiss: { refresh += 1 }) {
            DemandWorktreesManager(item: item, cacheURL: cacheURL)
        }
    }

    private var summaryText: String {
        guard let summary else { return "读取中" }
        if summary.error != nil { return "台账待核对" }
        let registered = summary.registered ?? 0
        return registered == 0 ? "尚未登记" : "登记 \(registered) 个 · 已清理 \(summary.removed ?? 0) 个"
    }
}

struct DemandWorktreesManager: View {
    @Environment(\.dismiss) private var dismiss
    let item: DItem
    let cacheURL: URL
    @State private var rows: [DemandWorktreeRow] = []
    @State private var revision: String?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    @State private var confirming = false
    @State private var directory = ""
    @State private var created = false
    @State private var details: Set<String> = []
    @State private var failures: [String: String] = [:]

    private var eligibleCount: Int { rows.filter(\.eligible).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("工作树 · " + item.id + " " + item.displayTitle, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("刷新") { perform("preview") }.disabled(busy)
            }
            Text(item.status == .completed
                 ? "只清理本需求创建且代码已保存、已推送的工作树。分支和提交保留，后续仍可恢复或审查。"
                 : "记录本需求使用的所有工作树，完结后可集中清理。复用其他需求的目录，只登记使用。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty && !busy {
                        Text("尚无工作树记录。新建工作树的 AI 会按接手规则登记，已有目录可以在下方补登记。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: row.state == "removed" ? "checkmark.circle" : (row.eligible ? "checkmark.circle.fill" : "pause.circle"))
                                    .foregroundStyle(row.eligible ? Color.green : .secondary)
                                Text(row.name).font(.system(size: 13, weight: .semibold))
                                Text(row.branch).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Button(details.contains(row.id) ? "收起" : "详情") {
                                    if details.contains(row.id) { details.remove(row.id) } else { details.insert(row.id) }
                                }.controlSize(.small)
                            }
                            Text(row.reason).font(.system(size: 12)).foregroundStyle(row.eligible ? Color.green : .secondary)
                            if row.eligible, let failure = failures[row.id] {
                                Text("本次未清理：" + failure).font(.system(size: 12)).foregroundStyle(.orange)
                            }
                            if details.contains(row.id) {
                                Text(row.path).font(.system(size: 11)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(row.created_by_task ? "归属：本需求创建" : "归属：仅使用，不能清理")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                if row.ignored_files && row.eligible {
                                    Text("目录内的忽略文件（如编译产物、依赖和本地配置）也会随目录移除。")
                                        .font(.system(size: 11)).foregroundStyle(.orange)
                                }
                            }
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Text("补登记").font(.system(size: 12, weight: .medium))
                Text(directory.isEmpty ? "选择工作树根目录" : directory)
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("选择目录") { chooseDirectory() }.disabled(busy)
            }
            HStack {
                Toggle("确认此工作树由本需求创建", isOn: $created).font(.system(size: 12))
                Spacer()
                Button("登记") { perform("register", extra: ["--path", directory, "--expect-title", item.displayTitle] + (created ? ["--created"] : [])) }
                    .disabled(directory.isEmpty || busy)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(failed ? Color.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(item.status == .completed ? "可清理 \(eligibleCount) 个，其余保留并说明原因" : "需求完结后开放清理")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if item.status == .completed {
                    Button("清理 \(eligibleCount) 个工作树", role: .destructive) { confirming = true }
                        .disabled(busy || eligibleCount == 0 || revision == nil)
                        .accessibilityIdentifier("worktrees-cleanup-" + item.id)
                }
            }
        }
        .padding(24).frame(minWidth: 640, idealWidth: 720, minHeight: 500, idealHeight: 580)
        .interactiveDismissDisabled(busy)
        .onAppear { perform("preview") }
        .alert("清理 \(eligibleCount) 个工作树？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("确认清理", role: .destructive) {
                if let revision { perform("cleanup", extra: ["--expect-preview", revision]) }
            }
        } message: {
            Text("将移除预览中可清理的目录，分支和提交保留。目录内的忽略文件，包括依赖、编译产物和本地配置，也会移除。执行前会再次核对；变化或被占用的目录会跳过。")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择工作树"
        if panel.runModal() == .OK, let url = panel.url { directory = url.path; created = false }
    }

    private func perform(_ mode: String, extra: [String] = []) {
        guard !busy else { return }
        busy = true; message = nil; failed = false
        if mode != "cleanup" { failures = [:] }
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> Result<(DemandWorktreeResponse, DemandWorktreeResponse), Error> in
                do {
                    let result = try DemandWorktreeCLI.run(cache: cacheURL, mode: mode, id: item.id, extra: extra)
                    let latest = mode == "preview" ? result : try DemandWorktreeCLI.run(cache: cacheURL, mode: "preview", id: item.id)
                    return .success((result, latest))
                } catch { return .failure(error) }
            }.value
            busy = false
            switch outcome {
            case .success(let (result, latest)):
                rows = latest.rows ?? []; revision = latest.preview_revision
                if mode == "register" { directory = ""; created = false; message = "工作树已登记。" }
                if mode == "cleanup" {
                    failures = Dictionary(uniqueKeysWithValues: (result.results ?? []).filter { !$0.removed }.map { ($0.id, $0.reason) })
                    message = "已清理 \(result.removed_count ?? 0) 个工作树；其余状态见列表。"
                }
            case .failure(let error):
                revision = nil; failed = true; message = error.localizedDescription
            }
        }
    }
}
