import Foundation
import SwiftUI
import AppKit

enum DemandDeliveryError: LocalizedError {
    case message(String)
    case missingTechnicalPlan(DItem)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .missingTechnicalPlan: return "尚未准备技术方案，请先复制方案指令交给 AI。"
        }
    }
}

struct DemandDeliveryProject: Codable, Equatable {
    let name: String
    let branch: String
    var declaration: String { name + ":" + branch }

    static func name(_ value: String) -> String {
        let path = NSString(string: value.trimmed).expandingTildeInPath
        return path.contains("/") ? URL(fileURLWithPath: path).lastPathComponent : path
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && !["待定", "待补充", "（待补充）"].contains(value)
            && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    static func isIntegrationBranch(_ value: String) -> Bool {
        let branch = value.lowercased()
        return ["pre", "staging", "release", "integration"].contains(branch) ||
            branch.hasPrefix("merge/") || branch.hasPrefix("integration/") || branch.hasPrefix("release/")
    }

    static func validBranch(_ value: String) -> Bool {
        !value.isEmpty && !["待定", "待补充", "HEAD"].contains(value)
            && !value.contains("..") && !value.contains("@{")
            && value.rangeOfCharacter(from: CharacterSet(charactersIn: " ,;，；：:\\~^?*[\n\r\t")) == nil
            && !value.hasPrefix("-") && !value.hasSuffix("/") && !value.hasSuffix(".lock")
    }
}

struct DemandDeliveryPlan {
    static let folder = "https://alidocs.dingtalk.com/i/nodes/Qnp9zOoBVBZbY5railO7bDOeV1DK0g6l"
    static let feedbackSummary = "技术说明和工程分支已提交为开发交付物。"
    let item: DItem
    let link: ReqFlowLink
    let projects: [DemandDeliveryProject]
    let key: String
    var technicalNotes: String = ""

    func includingReference(_ notes: String) -> Self {
        Self(item: item, link: link, projects: projects,
            key: notes.isEmpty ? key : ContentRevision.hash(key + "\nreference:\n" + notes), technicalNotes: notes)
    }

    static func load(id: String, at url: URL = URL(fileURLWithPath: CacheFile.path),
                     repositoryName: (String) throws -> String = gitRepositoryName,
                     codeRevision: ([DemandVersion.Repository]) -> String? = DemandTechnicalPlan.currentCodeRevision) throws -> Self {
        guard let snapshot = CacheFile.withLock(at: url, {
            Result<(DItem, [String]), Error> {
                let text = try String(contentsOf: url, encoding: .utf8)
                let matches = CacheParser.parse(content: text).items.filter { $0.id == id }
                guard matches.count == 1, let item = matches.first,
                      item.changeReadError == nil, item.versionReadError == nil, item.chatReadError == nil,
                      let range = DItemStore.blockRange(text.components(separatedBy: "\n"), id: id) else {
                    throw DemandDeliveryError.message("无法读取这条需求的最新现状，请刷新后重试。")
                }
                let block = Array(text.components(separatedBy: "\n")[range])
                for field in ["项目", "分支", "需求流", "提示词", "描述"] {
                    guard block.filter({ $0.hasPrefix("- **" + field + "**") }).count <= 1 else {
                        throw DemandDeliveryError.message("需求字段重复，请先核对再提交。")
                    }
                }
                return (item, block)
            }
        }) else { throw DemandDeliveryError.message("需求数据暂时无法读取，请重试。") }
        let (item, block) = try snapshot.get()
        if item.technicalPlan == nil && item.technicalPlanReadError == nil {
            throw DemandDeliveryError.missingTechnicalPlan(item)
        }
        let prefix = "<!-- dboard-ai-feedback:v1:"
        let repositories = block.contains { $0.hasPrefix(prefix) }
            ? try DemandVersion.repositoryHints(block, item: item) : []
        let plan = try make(item: item, repositories: repositories, repositoryName: repositoryName)
        guard let document = item.technicalPlan,
              document.reviewReason(item: item, codeRevision: codeRevision(repositories)) == nil else {
            throw DemandDeliveryError.message("技术方案与当前需求或代码不匹配，请先让 AI 核对更新。")
        }
        return plan
    }

    static func make(item: DItem, repositories: [DemandVersion.Repository] = [],
                     repositoryName: (String) throws -> String = gitRepositoryName) throws -> Self {
        guard let link = item.reqFlow, link.isValid else {
            throw DemandDeliveryError.message("请先关联需求流里的需求。")
        }
        let declared = DemandRepositoryEntries.parse(item.project)
        let branchText = (item.branch ?? "").trimmed
        var projects: [DemandDeliveryProject] = []

        // A manually edited branch field is authoritative; do not silently replace it with old AI metadata.
        if branchText.contains(":") || branchText.contains("：") {
            let entries = branchText.components(separatedBy: CharacterSet(charactersIn: "；;\n\r"))
            for entry in entries where !entry.trimmed.isEmpty {
                let parts = entry.replacingOccurrences(of: "：", with: ":")
                    .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw DemandDeliveryError.message("请为每个工程填写对应分支。") }
                let raw = String(parts[0]).trimmed
                let name = (raw.hasPrefix("/") || raw.hasPrefix("~")) ? try repositoryName(raw) : DemandDeliveryProject.name(raw)
                projects.append(DemandDeliveryProject(name: name, branch: String(parts[1]).trimmed))
            }
            let names = try declared.map { raw -> String in
                (raw.hasPrefix("/") || raw.hasPrefix("~")) ? try repositoryName(raw) : DemandDeliveryProject.name(raw)
            }
            guard names.allSatisfy({ name in projects.contains { $0.name == name } }) else {
                throw DemandDeliveryError.message("部分项目没有对应分支，请在分支栏按“工程:分支”逐个填写。")
            }
        } else {
            guard declared.count == 1 else {
                throw DemandDeliveryError.message(declared.isEmpty ? "请先填写项目和分支。" : "多个项目请在分支栏按“工程:分支”逐个填写。")
            }
            let raw = declared[0]
            var name = DemandDeliveryProject.name(raw)
            if (raw.hasPrefix("/") || raw.hasPrefix("~")) { name = try repositoryName(raw) }
            else if let match = repositories.first(where: { DemandDeliveryProject.name($0.path) == raw }) {
                name = try repositoryName(match.path)
            } else if repositories.count == 1, declared.count == 1 {
                let resolved = try repositoryName(repositories[0].path)
                guard resolved == name else { throw DemandDeliveryError.message("项目名称与已记录仓库不一致，请核对后再提交。") }
            }
            projects = [DemandDeliveryProject(name: name, branch: branchText)]
        }
        guard !projects.isEmpty,
              projects.allSatisfy({ DemandDeliveryProject.validName($0.name) && DemandDeliveryProject.validBranch($0.branch) }),
              Set(projects.map(\.name)).count == projects.count else {
            throw DemandDeliveryError.message("项目或分支不完整、重复或格式不正确，请先编辑补全。")
        }
        if let project = projects.first(where: { DemandDeliveryProject.isIntegrationBranch($0.branch) }) {
            throw DemandDeliveryError.message("\(project.name) 的 \(project.branch) 是合并分支，请先填写本需求的实际开发分支再提交。")
        }
        guard let document = item.technicalPlan, document.isValid, item.technicalPlanReadError == nil else {
            throw DemandDeliveryError.message(item.technicalPlanReadError ?? "尚未准备技术方案，请先复制方案指令交给 AI。")
        }
        guard document.scopeHash == item.executionScope else {
            throw DemandDeliveryError.message("需求已变化，请先让 AI 核对技术方案。")
        }
        guard Set(document.projects.map(\.declaration)) == Set(projects.map(\.declaration)),
              !projects.contains(where: { project in item.environmentRepositories.contains {
                  $0.branch == project.branch && (try? repositoryName($0.path)) == project.name
              } }) else {
            throw DemandDeliveryError.message("方案中的开发分支与当前记录不一致，或使用了预发／发布分支，请先核对。")
        }
        let identity = document.revision + "\0" + String(link.id) + "\0" + link.no
        return Self(item: item, link: link, projects: projects, key: ContentRevision.hash(identity))
    }

    static func gitRepositoryName(_ path: String) throws -> String {
        let path = NSString(string: path).expandingTildeInPath
        let result = ProcessRunner.run("/usr/bin/git", arguments: ["-C", path, "remote", "get-url", "origin"],
            environment: ProcessInfo.processInfo.environment, timeout: 5)
        guard result.succeeded else {
            // Git common-dir resolves worktrees even when no origin is configured.
            let common = ProcessRunner.run("/usr/bin/git", arguments: ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                environment: ProcessInfo.processInfo.environment, timeout: 5)
            guard common.succeeded else { throw DemandDeliveryError.message("无法确认仓库工程名：\(DemandDeliveryProject.name(path))，请检查仓库路径。") }
            let directory = URL(fileURLWithPath: String(decoding: common.stdout, as: UTF8.self).trimmed)
            return directory.lastPathComponent == ".git" ? directory.deletingLastPathComponent().lastPathComponent
                : directory.deletingPathExtension().lastPathComponent
        }
        let remote = String(decoding: result.stdout, as: UTF8.self).trimmed
        let tail = remote.split(separator: "/").last.map(String.init) ?? remote
        let name = tail.split(separator: ":").last.map(String.init) ?? tail
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    func document() -> String {
        item.technicalPlan?.markdown ?? ""
    }

    func matches(_ response: DevelopmentDeliverables.Response, url: String) -> Bool {
        response.items.contains { item in
            guard item["_tag"] as? String == "dev",
                  let content = item["deliverableContent"] as? String,
                  content.trimmingCharacters(in: .whitespacesAndNewlines) == url else { return false }
            let actual = DeclaredDevelopmentProject.parse([item["deliverableDevProject"] as? String ?? ""])
            return Set(actual.map { $0.project + ":" + ($0.branch ?? "") }) == Set(projects.map(\.declaration))
        }
    }
}

struct DemandDeliveryReceipt: Codable {
    let key: String
    let itemID: String
    let reqID: Int
    let title: String
    var markdown: String
    var documentURL: String?
    var creating = false
    var submitting = false
    var confirmed = false
    var progressRecorded = false
    var previousDocumentMarkdown: String? = nil
    var previousDocumentTitle: String? = nil
}

final class DemandDeliveryStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/dboard-development-deliveries.json")
    let url: URL
    init(url: URL = defaultURL) { self.url = url }
    func read() throws -> [String: DemandDeliveryReceipt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do { return try JSONDecoder().decode([String: DemandDeliveryReceipt].self, from: Data(contentsOf: url)) }
        catch { throw DemandDeliveryError.message("本地交付记录无法读取，已停止，避免重复提交。") }
    }
    func save(_ receipt: DemandDeliveryReceipt) throws {
        var records = try read()
        records[receipt.key] = receipt
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}

struct DemandDeliveryServices {
    var generate: (DemandDeliveryPlan) throws -> String
    var validate: (ReqFlowLink) throws -> Void
    var findDocument: (String) throws -> String?
    var createDocument: (String, String) throws -> String
    var verifyDocument: (String, String) throws -> Void
    var listDeliverables: (Int) throws -> DevelopmentDeliverables.Response
    var submit: (DemandDeliveryPlan, String) throws -> Void
    var readDocument: ((String) throws -> String)? = nil
    var updateDocument: ((String, String) throws -> Void)? = nil
    var renameDocument: ((String, String, String) throws -> Void)? = nil
}

/// Serialized durable checkpoints protect retries even across application restarts.
final class DemandDeliveryWorkflow {
    let store: DemandDeliveryStore
    let services: DemandDeliveryServices
    init(store: DemandDeliveryStore = DemandDeliveryStore(), services: DemandDeliveryServices = .live) {
        self.store = store; self.services = services
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    func run(_ plan: DemandDeliveryPlan, stillCurrent: () throws -> Bool,
             phase: (String) -> Void = { _ in }) throws -> DemandDeliveryReceipt {
        try services.validate(plan.link)
        let records = try store.read()
        let previous = records.values.filter { $0.itemID == plan.item.id && $0.reqID == plan.link.id && $0.confirmed && $0.documentURL != nil }
            .sorted { $0.title < $1.title }.last
        var receipt = records[plan.key] ?? DemandDeliveryReceipt(key: plan.key, itemID: plan.item.id,
            reqID: plan.link.id, title: "\(plan.link.no)-\(plan.item.id) \(plan.item.technicalPlan?.title ?? plan.item.displayTitle + " · 技术方案")",
            markdown: "", documentURL: previous?.documentURL, previousDocumentMarkdown: previous?.markdown,
            previousDocumentTitle: previous?.title)
        guard receipt.key == plan.key, receipt.itemID == plan.item.id, receipt.reqID == plan.link.id else {
            throw DemandDeliveryError.message("本地交付记录与需求不一致，已停止提交。")
        }
        if receipt.markdown.isEmpty {
            phase("读取已准备的技术方案…")
            receipt.markdown = try services.generate(plan)
            try store.save(receipt)
        }
        guard try stillCurrent() else { throw DemandDeliveryError.message("需求现状已变化，未提交；请按最新现状重新操作。") }
        if receipt.documentURL == nil {
            phase("保存到钉钉目录…")
            if let existing = try services.findDocument(receipt.title) { receipt.documentURL = existing }
            else {
                guard !receipt.creating else {
                    throw DemandDeliveryError.message("上次创建文档的结果不确定，目录中尚未找到；请稍后重试，或检查技术交付物目录。")
                }
                receipt.creating = true
                try store.save(receipt)
                do { receipt.documentURL = try services.createDocument(receipt.title, receipt.markdown) }
                catch let error as DemandDeliveryDocumentRejected {
                    receipt.creating = false
                    try store.save(receipt)
                    throw error
                }
            }
            receipt.creating = false
            try store.save(receipt)
        }
        guard let url = receipt.documentURL else { throw DemandDeliveryError.message("未取得技术文档链接。") }
        phase("核验技术方案与交付物…")
        if let previousMarkdown = receipt.previousDocumentMarkdown, previousMarkdown != receipt.markdown {
            guard let read = services.readDocument, let update = services.updateDocument else {
                throw DemandDeliveryError.message("已有方案需要更新，请核对文档后重试。")
            }
            let actual = try read(url)
            if !DemandDeliveryDocumentVerification.matches(actual: actual, expected: receipt.markdown) {
                guard DemandDeliveryDocumentVerification.matches(actual: actual, expected: previousMarkdown) else {
                    throw DemandDeliveryError.message("远端技术方案已被修改，内容已保留；请核对后再提交。")
                }
                guard try stillCurrent() else { throw DemandDeliveryError.message("需求或代码已变化，方案未更新、交付物未提交。") }
                phase("更新已有技术方案…")
                try update(url, receipt.markdown)
            }
        }
        try services.verifyDocument(url, receipt.markdown)
        if let oldTitle = receipt.previousDocumentTitle, oldTitle != receipt.title, let rename = services.renameDocument {
            try rename(url, oldTitle, receipt.title)
        }
        receipt.previousDocumentMarkdown = nil
        receipt.previousDocumentTitle = nil
        try store.save(receipt)
        let remote = try services.listDeliverables(plan.link.id)
        if plan.matches(remote, url: url) {
            receipt.confirmed = true; receipt.submitting = false
            try store.save(receipt)
            return receipt
        }
        guard !receipt.submitting, !receipt.confirmed else {
            throw DemandDeliveryError.message("上次提交结果尚未核实，未重复提交；请打开需求流确认后再重试。")
        }
        guard try stillCurrent() else { throw DemandDeliveryError.message("需求现状已变化，文档已保留，交付物未提交。") }
        phase("提交开发交付物…")
        receipt.submitting = true
        try store.save(receipt)
        do { try services.submit(plan, url) }
        catch let error as DemandDeliverySubmissionRejected {
            receipt.submitting = false
            try store.save(receipt)
            throw DemandDeliveryError.message(error.message)
        }
        // A lost response remains pending; the next attempt only checks the server.
        guard plan.matches(try services.listDeliverables(plan.link.id), url: url) else {
            throw DemandDeliveryError.message("提交已发出，暂未读取到结果；请稍后重试核验，不会重复上传。")
        }
        receipt.confirmed = true; receipt.submitting = false
        try store.save(receipt)
        return receipt
    }
}

struct DemandDeliveryDocumentRejected: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DemandDeliverySubmissionRejected: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DemandDeliveryState {
    var running = false
    var message = ""
    var failed = false
    var documentURL: String?
}

final class DemandDeliveryCoordinator: ObservableObject {
    @Published private(set) var states: [String: DemandDeliveryState] = [:]
    private let queue = DispatchQueue(label: "com.zz.dboard.development-delivery", qos: .utility)
    let workflow: DemandDeliveryWorkflow
    let cacheURL: URL
    private let copyPlanInstruction: (String) -> Bool
    init(workflow: DemandDeliveryWorkflow = DemandDeliveryWorkflow(),
         cacheURL: URL = URL(fileURLWithPath: CacheFile.path),
         copyPlanInstruction: @escaping (String) -> Bool = {
             NSPasteboard.general.clearContents()
             return NSPasteboard.general.setString($0, forType: .string)
         }) {
        self.workflow = workflow; self.cacheURL = cacheURL
        self.copyPlanInstruction = copyPlanInstruction
    }

    func prepare(id: String, completion: @escaping (DemandDeliveryPlan?) -> Void) {
        guard states[id]?.running != true else { return }
        states[id] = DemandDeliveryState(running: true, message: "核对方案与开发分支…")
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let plan = try DemandDeliveryPlan.load(id: id, at: self.cacheURL)
                DispatchQueue.main.async { self.states[id] = DemandDeliveryState(); completion(plan) }
            } catch DemandDeliveryError.missingTechnicalPlan(let item) {
                DispatchQueue.main.async {
                    let instruction = DboardAITaskContext.planInstruction(item: item,
                        cacheURL: self.cacheURL.path == CacheFile.path ? nil : self.cacheURL)
                    let copied = self.copyPlanInstruction(instruction)
                    self.states[id] = DemandDeliveryState(
                        message: copied ? "技术方案尚未准备，生成指令已复制，发给 AI 即可。"
                            : "技术方案尚未准备，复制指令失败，请点击「复制方案指令」重试。",
                        failed: true)
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.states[id] = DemandDeliveryState(message: error.localizedDescription, failed: true)
                    completion(nil)
                }
            }
        }
    }

    func submit(id: String, expectedKey: String? = nil, refresh: @escaping (Int) -> Void) {
        guard states[id]?.running != true else { return }
        states[id] = DemandDeliveryState(running: true, message: "读取最新现状…")
        queue.async { [weak self] in
            guard let self else { return }
            var key: String?
            do {
                let plan = try DemandDeliveryPlan.load(id: id, at: self.cacheURL)
                guard expectedKey == nil || expectedKey == plan.key else {
                    throw DemandDeliveryError.message("技术方案或开发分支已变化，请重新预览后提交。")
                }
                key = plan.key
                var receipt = try self.workflow.run(plan, stillCurrent: {
                    try DemandDeliveryPlan.load(id: id, at: self.cacheURL).key == plan.key
                }, phase: { message in DispatchQueue.main.async { self.states[id]?.message = message } })
                if !receipt.progressRecorded {
                    let latest = try DItemStore.currentItem(id: id, at: self.cacheURL)
                    if latest.reqFlow == plan.link {
                        let details = "技术说明：" + (receipt.documentURL ?? "") + "\n工程与分支：" +
                            plan.projects.map(\.declaration).joined(separator: "；") + "\n仅提交开发交付物，需求状态未改变。"
                        receipt.progressRecorded = latest.milestones.contains {
                            $0.content == DemandDeliveryPlan.feedbackSummary && $0.details == details
                        } || DItemStore.appendProgress(id: id, text: DemandDeliveryPlan.feedbackSummary,
                            details: details, at: self.cacheURL)
                        try self.workflow.store.save(receipt)
                    }
                }
                let message = receipt.progressRecorded ? "开发交付物已提交" : "开发交付物已提交，本地进度未保存，请刷新核对"
                DispatchQueue.main.async {
                    self.states[id] = DemandDeliveryState(message: message, failed: !receipt.progressRecorded,
                        documentURL: receipt.documentURL)
                    refresh(plan.link.id)
                }
            } catch {
                let documentURL = key.flatMap { try? self.workflow.store.read()[$0]?.documentURL }
                DispatchQueue.main.async {
                    self.states[id] = DemandDeliveryState(message: error.localizedDescription, failed: true, documentURL: documentURL ?? nil)
                }
            }
        }
    }
}

struct DemandDeliveryAction: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let item: DItem
    @ObservedObject var coordinator: DemandDeliveryCoordinator
    let refresh: (Int) -> Void
    private var state: DemandDeliveryState { coordinator.states[item.id] ?? DemandDeliveryState() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DemandTechnicalPlanSection(item: item, cacheURL: coordinator.cacheURL)
            HStack {
                Button(state.running ? state.message : "提交开发交付", systemImage: "square.and.arrow.up") {
                    coordinator.prepare(id: item.id) { plan in
                        if let plan { vm.openDemandEditor(.delivery, item: plan.item, deliveryPlan: plan) }
                    }
                }
                .controlSize(.small).disabled(state.running)
                .accessibilityIdentifier("demand-development-delivery-" + item.id).demandKeyboardID("demand-development-delivery-" + item.id)
                Spacer()
                if let url = state.documentURL, let target = URL(string: url) {
                    Link("查看技术方案", destination: target).font(.system(size: 11))
                }
            }
            if !state.running && !state.message.isEmpty {
                Text(state.message).font(.system(size: 11)).foregroundStyle(state.failed ? Color.orange : Color.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DemandDeliveryPreviewView: View {
    let plan: DemandDeliveryPlan
    let close: () -> Void
    let submit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("确认开发交付").font(.system(size: 17, weight: .semibold))
                Text(plan.link.no + " · " + plan.item.displayTitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("开发工程与分支").font(.system(size: 12, weight: .semibold))
                    Text("\(plan.projects.count) 个工程").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ScrollView(.vertical) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        ForEach(plan.projects, id: \.name) { project in
                            GridRow {
                                Text(project.name)
                                Text(project.branch).foregroundStyle(.tint).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .scrollIndicators(.visible)
                .scrollIndicatorsFlash(onAppear: true)
                .frame(height: min(CGFloat(max(plan.projects.count, 1)) * 26 + 16, 112))
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("技术方案").font(.system(size: 13, weight: .semibold))
                ScrollView(.vertical) {
                    DemandTechnicalPlanBody(markdown: plan.document())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .scrollIndicators(.visible)
                .scrollIndicatorsFlash(onAppear: true)
                .frame(minHeight: 300, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
                .accessibilityIdentifier("demand-delivery-plan-scroll").demandKeyboardID("demand-delivery-plan-scroll")
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("确认后保存／更新技术方案，并提交以上开发分支。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("返回核对", action: close).keyboardShortcut(.cancelAction)
                    Button("确认提交", action: submit).demandButtonStyle(.borderedProminent)
                        .accessibilityIdentifier("demand-delivery-confirm").demandKeyboardID("demand-delivery-confirm")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 820, maxWidth: .infinity,
               minHeight: 700, idealHeight: 780, maxHeight: .infinity)
        .background { DemandCanvasBackground() }
    }
}
