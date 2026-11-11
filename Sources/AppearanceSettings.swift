import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var theme: ThemeManager
    @ObservedObject private var font = FontManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("皮肤").dboardFont(size: 18, weight: .semibold)
                        Text("点击即刻应用，深浅色随系统切换。")
                            .dboardFont(size: 12).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复默认") { theme.restoreDefault() }
                        .disabled(theme.current == .defaultTheme)
                        .accessibilityIdentifier("appearance-restore")
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(DBoardTheme.all) { palette in
                        SkinPreviewCard(palette: palette, selected: theme.current == palette) {
                            theme.current = palette
                        }
                    }
                }
                Divider()
                HStack {
                    Text("字体").dboardFont(size: 13, weight: .medium)
                    Spacer()
                    Picker("字体", selection: $font.current) {
                        ForEach(DBoardFont.all) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                    .accessibilityLabel("界面字体")
                }
            }.padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SkinPreviewCard: View {
    let palette: DBoardTheme
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    miniature(scheme: .light)
                    miniature(scheme: .dark)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(palette.name).dboardFont(size: 13, weight: .semibold)
                        Text(palette.summary).dboardFont(size: 11).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .dboardFont(size: 16).foregroundStyle(palette.accentPrimary)
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? palette.accentPrimary.opacity(0.75) : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 1.5 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appearance-skin-" + palette.id)
        .accessibilityLabel(palette.name + "，" + palette.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func miniature(scheme: ColorScheme) -> some View {
        SkinMiniature(palette: palette, scheme: scheme)
            .environment(\.colorScheme, scheme)
    }
}

/// A small real surface preview, without images or rebuilding the user's open windows.
private struct SkinMiniature: View {
    let palette: DBoardTheme
    let scheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("D板").dboardFont(size: 10, weight: .semibold)
                Spacer()
                Circle().fill(palette.accentPrimary).frame(width: 5, height: 5)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("D014").font(.system(size: 7, design: .monospaced)).foregroundStyle(.secondary)
                Text("需求与排查").dboardFont(size: 9, weight: .medium)
                RoundedRectangle(cornerRadius: 2).fill(palette.accentPrimary.opacity(0.5))
                    .frame(width: 38, height: 3)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background { ThemeCardFill(palette: palette, opacity: palette.floatingCardOpacity(for: scheme)) }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            HStack {
                Text(scheme == .dark ? "深色" : "浅色").dboardFont(size: 8).foregroundStyle(.secondary)
                Spacer()
                RoundedRectangle(cornerRadius: 3).fill(palette.controlAccent).frame(width: 24, height: 10)
            }
        }
        .foregroundStyle(.primary)
        .padding(10).frame(maxWidth: .infinity)
        .background { ThemeCanvasBackground(palette: palette) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
