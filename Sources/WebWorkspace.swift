import SwiftUI
import AppKit

enum WebWorkspacePage: String, CaseIterable, Identifiable, Codable {
    case appRelease, logs, audi
    var id: String { rawValue }
    var title: String {
        switch self { case .appRelease: return "应用发布台"; case .logs: return "Audi 日志"; case .audi: return "Audi 首页" }
    }
    var subtitle: String {
        switch self { case .appRelease: return "发布与部署"; case .logs: return "查询与排查日志"; case .audi: return "研发测试工具" }
    }
    var symbol: String {
        switch self { case .appRelease: return "shippingbox"; case .logs: return "doc.text.magnifyingglass"; case .audi: return "square.grid.2x2" }
    }
    var url: URL {
        switch self {
        case .appRelease: return URL(string: "https://audi.tmallyc.com/app-release")!
        case .logs: return URL(string: "https://audi.tmallyc.com/logs-hist")!
        case .audi: return URL(string: "https://audi.tmallyc.com/")!
        }
    }
    var moduleID: String { self == .audi ? "audihome" : (self == .logs ? "logs" : "apprelease") }
    func moved(_ direction: Int) -> Self {
        let pages = Self.allCases
        let index = pages.firstIndex(of: self) ?? 0
        return pages[(index + direction % pages.count + pages.count) % pages.count]
    }
}

final class WebWorkspacePreferences: ObservableObject {
    static let shared = WebWorkspacePreferences()
    @Published var defaultPage: WebWorkspacePage {
        didSet { defaults.set(defaultPage.rawValue, forKey: "webworkspace.defaultPage") }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "webworkspace.defaultPage")
        defaultPage = saved == "reqflow" ? .logs : saved.flatMap(WebWorkspacePage.init(rawValue:)) ?? .appRelease
        if saved == "reqflow" { defaults.set(defaultPage.rawValue, forKey: "webworkspace.defaultPage") }
    }
}

final class WebWorkspaceLocation: ObservableObject {
    @Published var page: WebWorkspacePage
    @Published var url: URL
    init(page: WebWorkspacePage) { self.page = page; url = page.url }
    func update(page: WebWorkspacePage, url: URL?) {
        self.page = page
        self.url = url.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil } ?? page.url
    }
}

/// Shared navigation controls, with each window keeping its own actual current URL.
struct WebWorkspaceNavigationBar: View {
    @ObservedObject var location: WebWorkspaceLocation
    var navigate: (WebWorkspacePage) -> Void = { WebWorkspaceRouter.open($0) }
    @State private var fullURL = false
    @State private var copied = false
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        HStack(spacing: 8) {
            ForEach(WebWorkspacePage.allCases) { page in
                Button { navigate(page) } label: {
                    Text(page.title).dboardFont(size: 11, weight: location.page == page ? .medium : .regular)
                        .foregroundStyle(location.page == page ? theme.current.accentPrimary : theme.current.textSecondary)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(theme.current.accentPrimary.opacity(location.page == page ? 0.10 : 0),
                            in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                }.buttonStyle(DBoardPlainButtonStyle()).accessibilityIdentifier("webworkspace-page-" + page.id)
            }
            Rectangle().fill(theme.current.textSecondary.opacity(0.18)).frame(width: 1, height: 16).padding(.horizontal, 4)
            Button { fullURL = true } label: {
                Text(location.url.absoluteString).dboardFont(size: 11)
                    .foregroundStyle(theme.current.textSecondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(DBoardPlainButtonStyle()).accessibilityLabel("当前链接 " + location.url.absoluteString)
                .popover(isPresented: $fullURL) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(location.url.absoluteString).dboardFont(size: 13).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("浏览器打开") { NSWorkspace.shared.open(location.url) }
                            Spacer()
                            Button(copied ? "已复制" : "复制链接", action: copyURL)
                        }
                    }.padding(20).frame(width: 420).environmentObject(theme)
                }
            Button(action: copyURL) {
                Image(systemName: copied ? "checkmark" : "link").frame(width: 32, height: 32).contentShape(Rectangle())
            }.buttonStyle(DBoardPlainButtonStyle()).foregroundStyle(theme.current.accentPrimary)
                .accessibilityLabel("复制当前链接").accessibilityIdentifier("webworkspace-copy-url")
        }.padding(.horizontal, 12).frame(height: 42)
            .background(theme.current.background)
    }
    private func copyURL() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(location.url.absoluteString, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

enum WebWorkspaceRouter {
    static func open(_ page: WebWorkspacePage) {
        NotificationCenter.default.post(name: .init("DBoardModuleWillOpen"), object: nil)
        UsageStats.hit(page.moduleID); WorkspacePreferences.shared.remember(page.moduleID)
        BizMapBoardWindowController.shared.hideForWorkspaceSwitch()
        AppReleaseWindowController.shared.showWorkspace(page)
    }
    static func navigate(from page: WebWorkspacePage, direction: Int) { open(page.moved(direction)) }
    static func canNavigate(_ window: NSWindow, event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat, [UInt16(123), 124].contains(event.keyCode),
              event.modifierFlags.intersection([.control, .command, .option, .shift]).isEmpty,
              window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSTextView { return !text.isEditable && !text.hasMarkedText() }
        if let control = window.firstResponder as? NSControl { return !control.acceptsFirstResponder }
        return true
    }
}

final class WebWorkspaceCardModel: ObservableObject {
    @Published var selected: WebWorkspacePage
    init(defaultPage: WebWorkspacePage) { selected = defaultPage }
    func move(_ direction: Int) { selected = selected.moved(direction) }
}

struct WebWorkspaceQuickOpenView: View {
    @ObservedObject var model: WebWorkspaceCardModel
    @ObservedObject var preferences: WebWorkspacePreferences
    let enter: (WebWorkspacePage) -> Void
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                ForEach(WebWorkspacePage.allCases) { page in
                    Button { model.selected = page; enter(page) } label: {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Image(systemName: page.symbol).dboardFont(size: 24, weight: .light)
                                    .foregroundStyle(theme.current.accentPrimary)
                                Spacer()
                                if preferences.defaultPage == page {
                                    Text("默认").dboardFont(size: 9).foregroundStyle(theme.current.textSecondary)
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(page.title).dboardFont(size: 17, weight: .medium).foregroundStyle(theme.current.textPrimary)
                                Text(page.subtitle).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                            }
                        }.padding(20).frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
                            .workspaceSurface(radius: 17)
                            .overlay {
                                if model.selected == page {
                                    RoundedRectangle(cornerRadius: 17).stroke(theme.current.accentPrimary.opacity(0.85), lineWidth: 1.5)
                                        .matchedGeometryEffect(id: "page-choice", in: selection)
                                }
                            }.contentShape(RoundedRectangle(cornerRadius: 17))
                    }.buttonStyle(DBoardPlainButtonStyle()).accessibilityIdentifier("webworkspace-card-" + page.id)
                        .accessibilityAddTraits(model.selected == page ? .isSelected : [])
                }
            }
            HStack {
                Text(model.selected.url.host ?? "").dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                Spacer()
                Button(preferences.defaultPage == model.selected ? "默认打开此卡片" : "设为默认卡片") {
                    preferences.defaultPage = model.selected
                }.buttonStyle(DBoardPlainButtonStyle()).dboardFont(size: 11).foregroundStyle(theme.current.accentPrimary)
            }.padding(.horizontal, 4)
        }.padding(24).demandFloatingCanvas()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.17), value: model.selected)
    }
}

private final class WebWorkspacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WebWorkspaceQuickOpenWindowController: NSObject, NSWindowDelegate {
    static let shared = WebWorkspaceQuickOpenWindowController()
    private(set) var window: NSPanel?
    private(set) var model: WebWorkspaceCardModel
    private let preferences: WebWorkspacePreferences
    private let activates: Bool
    private let enterAction: (WebWorkspacePage) -> Void
    private var keyMonitor: Any?
    private var closing = false
    private let focusReturn = PanelFocusReturn()
    init(preferences: WebWorkspacePreferences = .shared, activates: Bool = true,
         enter: @escaping (WebWorkspacePage) -> Void = { WebWorkspaceRouter.open($0) }) {
        self.preferences = preferences; self.activates = activates; enterAction = enter
        model = WebWorkspaceCardModel(defaultPage: preferences.defaultPage)
    }
    func toggle() { if window?.isVisible == true { close() } else { show() } }
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        model.selected = preferences.defaultPage
        if activates { focusReturn.capture() }
        let panel = WebWorkspacePanel(contentRect: NSRect(x: activates ? 0 : -10000, y: 0, width: 650, height: 222),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.level = .floating; panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: WebWorkspaceQuickOpenView(model: model, preferences: preferences,
            enter: { [weak self] in self?.enter($0) }).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared))
        window = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        if activates { centerWindowOnMouseScreen(panel); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { panel.orderBack(nil) }
    }
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.isVisible == true,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
        switch event.keyCode {
        case 123: if !event.isARepeat { model.move(-1) }; return nil
        case 124: if !event.isARepeat { model.move(1) }; return nil
        case 36, 76: enter(model.selected); return nil
        case 53: close(); return nil
        default: return event
        }
    }
    private func enter(_ page: WebWorkspacePage) { close(restoreFocus: false); enterAction(page) }
    func close(restoreFocus: Bool = true) {
        guard let window, !closing else { return }
        closing = true; window.close(); closing = false
        if activates && restoreFocus { focusReturn.restore() } else { focusReturn.discard() }
    }
    func windowDidResignKey(_ notification: Notification) { if window != nil { close(restoreFocus: false) } }
    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil; window = nil
    }
}
