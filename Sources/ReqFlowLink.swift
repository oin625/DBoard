import Foundation
import SwiftUI

/// Explicitly selected PRD identity. The Markdown link survives local edits, sync and archiving.
struct ReqFlowLink: Codable, Equatable {
    let id: Int
    let no: String
    var url: String { "https://ai.tmallyc.com/prd/index.html#detail/\(id)" }
    var isValid: Bool {
        id > 0 && no.range(of: #"^R[0-9]+$"#, options: .regularExpression) != nil
    }
    var markdown: String { "[\(no)](\(url))" }

    init(id: Int, no: String) { self.id = id; self.no = no }
    init(_ requirement: BizPRDItem) { self.init(id: requirement.id, no: requirement.no) }

    static func parseField(_ line: String) -> Self? {
        let pattern = #"^- \*\*需求流\*\*\s*[：:]\s*\[(R[0-9]+)\]\(https://ai\.tmallyc\.com/prd/index\.html#detail/([0-9]+)\)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let noRange = Range(match.range(at: 1), in: line),
              let idRange = Range(match.range(at: 2), in: line),
              let id = Int(line[idRange]), id > 0 else { return nil }
        return Self(id: id, no: String(line[noRange]))
    }
}

enum ReqFlowPickerScope: String, CaseIterable {
    case mine = "我的待办"
    case department = "组内需求"
}

enum ReqFlowLinkQueries {
    static func candidates(_ items: [BizPRDItem], scope: ReqFlowPickerScope, query: String) -> [BizPRDItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<Int>()
        return items.filter { item in
            let matchesScope = scope == .mine
                ? !item.completedForMe && (item.scopes.contains("pending") || item.scopes.contains("mine"))
                : item.scopes.contains("dept")
            return matchesScope && ReqFlowLink(item).isValid && seen.insert(item.id).inserted
                && (query.isEmpty || item.no.lowercased().contains(query)
                    || item.name.lowercased().contains(query) || item.status.lowercased().contains(query))
        }.sorted {
            let lhsPending = $0.scopes.contains("pending")
            let rhsPending = $1.scopes.contains("pending")
            if lhsPending != rhsPending { return lhsPending }
            return BizMapViewModel.prdSort($0, $1)
        }
    }

    static func linkedItem(for link: ReqFlowLink, in items: [DItem], excludingID: String? = nil) -> DItem? {
        items.first { $0.id != excludingID && $0.reqFlow?.id == link.id }
    }
}

extension DItemDraft {
    mutating func associate(with requirement: BizPRDItem, previous: BizPRDItem? = nil) {
        if name.trimmed.isEmpty || name == previous?.name { name = requirement.name }
        reqFlow = ReqFlowLink(requirement)
    }
}

struct ReqFlowLinkedRequirementView: View {
    let link: ReqFlowLink
    @ObservedObject var flow: BizMapViewModel
    let open: () -> Void

    private var requirement: BizPRDItem? { flow.prdItems.first { $0.id == link.id } }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Label(requirement?.no ?? link.no, systemImage: "link")
                    .font(.system(size: 11, design: .monospaced))
                Text("需求流：" + (requirement?.status ?? "本次列表未包含"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 6)
                Text("打开").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Image(systemName: "arrow.up.right.square").font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开关联需求 " + link.no)
        .help("正式状态来自需求流；个人状态在 D板单独记录")
    }
}

struct ReqFlowRequirementPicker: View {
    @ObservedObject var flow: BizMapViewModel
    let localItems: [DItem]
    let editingID: String
    let select: (BizPRDItem) -> Void
    let openExisting: (String) -> Void
    let cancel: () -> Void
    var refreshOnAppear = true
    @State var query = ""
    @State var scope: ReqFlowPickerScope = .mine
    @FocusState private var searchFocused: Bool

    private var candidates: [BizPRDItem] {
        ReqFlowLinkQueries.candidates(flow.prdItems, scope: scope, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("关联需求流").font(.system(size: 15, weight: .semibold))
                Spacer()
                if flow.regenerating { ProgressView().controlSize(.small) }
                Button { flow.refreshRequirements() } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("刷新需求流").disabled(flow.regenerating)
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
            }
            Text("选择已有需求，标题会带入 D板，正式状态可在关联处查看。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("搜索需求编号 / 标题 / 状态", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
            Picker("范围", selection: $scope) {
                ForEach(ReqFlowPickerScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if flow.authExpired {
                HStack {
                    Label("登录已过期，当前显示上次读取的需求", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("浏览器登录") { flow.openURL("https://ai.tmallyc.com/prd/index.html") }
                }.font(.system(size: 11))
            } else if let error = flow.genError ?? flow.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
            }
            if candidates.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: query.trimmed.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                    Text(query.trimmed.isEmpty ? "当前范围没有需求" : "没有匹配的需求")
                        .font(.system(size: 13))
                    if query.trimmed.isEmpty {
                        Button("刷新需求流") { flow.refreshRequirements() }.disabled(flow.regenerating)
                    } else {
                        Button("清空搜索") { query = "" }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(candidates) { requirement in
                            candidateRow(requirement)
                        }
                    }
                }
            }
            if let generated = flow.cache?.prdGenerated {
                Text("需求流快照：\(generated)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 540, maxWidth: 640, minHeight: 440, idealHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if refreshOnAppear { flow.load() }
            searchFocused = true
        }
    }

    private func candidateRow(_ requirement: BizPRDItem) -> some View {
        let existing = ReqFlowLinkQueries.linkedItem(for: ReqFlowLink(requirement),
            in: localItems, excludingID: editingID)
        return Button {
            if let existing { openExisting(existing.id) }
            else { select(requirement) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(requirement.name).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(3)
                HStack(spacing: 8) {
                    Text(requirement.no).font(.system(size: 11, design: .monospaced))
                    Text(requirement.status).font(.system(size: 11))
                    Spacer()
                    if let existing {
                        Text("已关联 \(existing.id) · 打开").foregroundStyle(Color.accentColor)
                    } else {
                        Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                    }
                }.foregroundStyle(.secondary).font(.system(size: 11))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

extension BizMapViewModel {
    /// Navigation uses the selected system ID; names never establish associations.
    @discardableResult
    func focusRequirement(_ link: ReqFlowLink) -> Bool {
        guard let requirement = prdItems.first(where: { $0.id == link.id }),
              !requirement.no.isEmpty else { return false }
        selected = nil
        perspective = .requirements
        query = requirement.no
        expandedPRD.insert(requirement.id)
        return true
    }
}
