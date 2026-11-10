import SwiftUI

private struct WorkspaceToolbarModifier: ViewModifier {
    let id: String
    let enabled: Bool
    func body(content: Content) -> some View {
        content.toolbar {
            if enabled {
                ToolbarItemGroup(placement: .automatic) {
                    WorkspacePinButton(id: id)
                    DBoardSettingsButton()
                }
            }
        }
    }
}

extension View {
    func workspaceToolbar(id: String, enabled: Bool = true) -> some View {
        modifier(WorkspaceToolbarModifier(id: id, enabled: enabled))
    }
}

struct DBoardModuleMenu: View {
    @ObservedObject private var flags = FeatureFlags.shared
    @ObservedObject private var shortcuts = ShortcutPreferences.shared
    var body: some View {
        Menu {
            ForEach(DBoardModule.visible) { module in
                Button { module.launch() } label: {
                    Label(module.shortcut.isEmpty ? module.title : "\(module.title)  \(module.shortcut)", systemImage: module.icon)
                }
            }
        } label: { Image(systemName: "square.grid.2x2") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
