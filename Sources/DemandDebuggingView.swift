import SwiftUI

struct DemandDebuggingView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @ObservedObject private var audi = LocalAudiServer.shared
    let item: DItem

    private var canLaunchLocal: Bool {
        guard !item.debugPageNotNeeded,
              item.debugPageReadError == nil,
              item.executionReadError == nil,
              !item.executionNeedsReview,
              let execution = item.execution,
              execution.debugPage != nil,
              [.debugPageReady, .testingPassed].contains(execution.stage) else { return false }
        return true
    }

    private var symbol: String {
        if item.debugPageReadError != nil { return "exclamationmark.circle" }
        if item.debugPageNotNeeded { return "minus.circle" }
        if item.executionReadError != nil || item.executionNeedsReview { return "exclamationmark.circle" }
        switch item.execution?.stage {
        case .testingPassed: return "checkmark.circle"
        case .debugPageReady: return "slider.horizontal.3"
        case .developmentComplete: return "checkmark.seal"
        default: return "hammer"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("调试测试", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                if item.debugPageNotNeeded {
                    Button("撤销无需调试页", systemImage: "arrow.uturn.backward") {
                        vm.setDebugPageNotNeeded(item.id, value: false)
                    }
                    .controlSize(.small)
                    .disabled(item.status == .completed || item.debugPageReadError != nil)
                    .accessibilityIdentifier("demand-debug-undo-" + item.id)
                } else {
                    Button("无需调试页") { vm.setDebugPageNotNeeded(item.id, value: true) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(minHeight: 28)
                        .disabled(item.status == .completed || item.debugPageReadError != nil)
                        .accessibilityIdentifier("demand-debug-skip-" + item.id)
                    Button { vm.copyDebugTask(item.id) } label: {
                        Label("复制调试咒言", systemImage: "wand.and.stars")
                    }
                    .controlSize(.small)
                    .disabled(item.status == .completed || item.executionReadError != nil || item.debugPageReadError != nil)
                    .help("交给 AI 核验开发，在 audi 建调试页，并记录试调结果")
                    .accessibilityIdentifier("demand-debug-copy-" + item.id)
                }
            }
            Label(item.executionLabel, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(item.debugPageReadError != nil || (!item.debugPageNotNeeded && (item.executionNeedsReview || item.executionReadError != nil)) ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !item.debugPageNotNeeded, let execution = item.execution, let page = execution.debugPage {
                HStack(spacing: 8) {
                    Text("audi · " + page).font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                    Spacer(minLength: 0)
                    if let address = execution.debugURL, let url = URL(string: address) {
                        Link(destination: url) { Label("打开调试页", systemImage: "arrow.up.right.square") }
                            .font(.system(size: 11))
                    }
                }
                if execution.debugURL == nil {
                    Text("页面路径已记录，访问地址待反馈").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if canLaunchLocal {
                    localDebugRow(page: page)
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func localDebugRow(page: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch audi.state {
            case .stopped:
                HStack(spacing: 8) {
                    Button { audi.startAndOpen(page: page) } label: {
                        Label("启动本地 audi", systemImage: "play.circle")
                    }
                    .controlSize(.small)
                    .help("在本地 audi 仓库运行开发服务，并在浏览器打开此调试页")
                    .accessibilityIdentifier("demand-debug-local-start-" + item.id)
                    Text("运行本地开发服务后在浏览器调试").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在启动本地 audi…").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("取消") { audi.stop() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(minHeight: 28)
                        .accessibilityIdentifier("demand-debug-local-cancel-" + item.id)
                }
            case .running(let base, let external):
                HStack(spacing: 8) {
                    Button { audi.open(page: page) } label: {
                        Label("打开本地调试页", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("demand-debug-local-open-" + item.id)
                    Text((external ? "本地 audi 已在运行 · " : "本地 audi 已启动 · ") + base.absoluteString)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                    Spacer(minLength: 0)
                    if !external {
                        Button("停止") { audi.stop() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(minHeight: 28)
                            .accessibilityIdentifier("demand-debug-local-stop-" + item.id)
                    }
                }
            case .failed(let message):
                HStack(spacing: 8) {
                    Button { audi.startAndOpen(page: page) } label: {
                        Label("重试启动本地 audi", systemImage: "arrow.clockwise.circle")
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("demand-debug-local-retry-" + item.id)
                    Spacer(minLength: 0)
                }
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("demand-debug-local-" + item.id)
    }
}
