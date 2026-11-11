import SwiftUI

/// Remains available when the demand is changed, hidden, archived, or filtered out.
struct LocalAudiServiceMenu: View {
    @ObservedObject var audi = LocalAudiServer.shared
    var body: some View {
        if audi.isActive {
            Button { audi.stop() } label: {
                Label(audi.state == .stopping ? "audi 停止中" : audi.isStarting ? "取消启动 audi" : "停止本地 audi",
                      systemImage: "stop.circle")
                    .dboardFont(size: 11)
            }
            .controlSize(.small)
            .disabled(audi.state == .stopping)
            .accessibilityIdentifier("local-audi-service-control")
        }
    }
}
