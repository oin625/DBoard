import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import Carbon.HIToolbox

extension View {
    func dboardDrawingLinks() -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard ExcalidrawDocument.handles(url) else { return .systemAction }
            ExcalidrawWindowManager.shared.open(url)
            return .handled
        })
    }
}

@MainActor
final class ExcalidrawWindowManager {
    static let shared = ExcalidrawWindowManager()
    private var controllers: [UUID: ExcalidrawWindowController] = [:]
    var activeController: ExcalidrawWindowController? {
        controllers.values.first { $0.window === NSApp.keyWindow }
    }
    var hasUnsavedChanges: Bool { controllers.values.contains { $0.isDirty || $0.isSaving } }

    func open(_ url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = controllers.values.first(where: { !$0.document.isUntitled && $0.document.url == canonical }) { existing.show(); return }
        do {
            show(try ExcalidrawDocument(url: canonical))
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开绘图"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
    func newDrawing() { show(ExcalidrawDocument()) }
    private func show(_ document: ExcalidrawDocument) {
        let id = UUID()
        let controller = ExcalidrawWindowController(document: document)
        controller.onClose = { [weak self] in self?.controllers.removeValue(forKey: id) }
        controllers[id] = controller
        controller.show()
    }
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "打开 Excalidraw 绘图"
        panel.allowedContentTypes = [UTType(filenameExtension: "excalidraw") ?? .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.filter(ExcalidrawDocument.handles).forEach(open) }
    }
    func prepareToQuit(_ completion: @escaping (Bool) -> Void) {
        let pending = Array(controllers.values)
        func next(_ index: Int) {
            guard index < pending.count else { completion(true); return }
            pending[index].confirmDiscardOrSave { accepted in
                if accepted { next(index + 1) } else { completion(false) }
            }
        }
        next(0)
    }
}

/// Serves only bundled assets. The scene itself enters through the native bridge.
final class ExcalidrawAssetHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "editor" else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let path = url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime: String
        switch file.pathExtension {
        case "html": mime = "text/html"
        case "js": mime = "application/javascript"
        case "css": mime = "text/css"
        case "woff2": mime = "font/woff2"
        case "woff": mime = "font/woff"
        case "ttf": mime = "font/ttf"
        default: mime = "application/octet-stream"
        }
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
private final class ExcalidrawBridge: NSObject, WKScriptMessageHandler {
    weak var owner: ExcalidrawWindowController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

private final class ExcalidrawNativeWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == [.command], event.keyCode == UInt16(kVK_ANSI_W), attachedSheet == nil {
            performClose(nil)
            return true
        }
        if flags == [.control, .command], event.keyCode == UInt16(kVK_ANSI_F) {
            toggleFullScreen(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ExcalidrawWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, WKUIDelegate, NSToolbarItemValidation {
    private(set) var document: ExcalidrawDocument
    let window: NSWindow
    let webView: WKWebView
    private(set) var isReady = false
    private(set) var isDirty = false
    private(set) var isSaving = false
    private(set) var lastError: String?
    var onClose: (() -> Void)?
    private var closed = false
    private var permitsClose = false
    private let bridge = ExcalidrawBridge()
    private let status = NSTextField(labelWithString: "正在打开绘图…")
    private let overlay = NSVisualEffectView()
    private let message = NSTextField(wrappingLabelWithString: "正在加载本地编辑器…")
    private let progress = NSProgressIndicator()
    private let retry = NSButton(title: "重新加载", target: nil, action: nil)
    private var readyTimer: Timer?
    private let activates: Bool
    private let resourceURL: URL?

    static func editorResources() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ExcalidrawEditor"),
            ProcessInfo.processInfo.environment["DBOARD_EXCALIDRAW_RESOURCES"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ExcalidrawEditor")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }
    init(document: ExcalidrawDocument, activates: Bool = true, resources: URL? = nil) {
        self.document = document; self.activates = activates
        resourceURL = resources ?? Self.editorResources()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let root = resourceURL { configuration.setURLSchemeHandler(ExcalidrawAssetHandler(root: root), forURLScheme: "dboard-drawing") }
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = ExcalidrawNativeWindow(contentRect: NSRect(x: activates ? 0 : -10000, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        bridge.owner = self
        configuration.userContentController.add(bridge, name: "dboardDrawing")
        webView.navigationDelegate = self; webView.uiDelegate = self
        window.delegate = self; window.isReleasedWhenClosed = false
        window.title = document.displayName
        window.representedURL = document.isUntitled ? nil : document.url
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 760, height: 540)
        window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
        window.setFrameAutosaveName("DBoardExcalidrawWindow")
        let toolbar = NSToolbar(identifier: "DBoardExcalidraw")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        let content = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor), webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor), webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        overlay.material = .windowBackground; overlay.blendingMode = .withinWindow; overlay.state = .active
        overlay.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(overlay)
        progress.style = .spinning; progress.controlSize = .regular; progress.startAnimation(nil)
        message.alignment = .center; message.font = .systemFont(ofSize: 13)
        retry.target = self; retry.action = #selector(reload); retry.bezelStyle = .rounded; retry.isHidden = true
        let stack = NSStackView(views: [progress, message, retry])
        stack.orientation = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor), overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
        window.contentView = content
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        loadEditor()
    }
    func show() {
        NotificationCenter.default.post(name: .init("DBoardModuleWillOpen"), object: nil)
        if activates {
            if !window.styleMask.contains(.fullScreen) { window.center() }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        else { window.orderBack(nil) }
    }
    private func loadEditor() {
        guard resourceURL != nil else { fail("缺少本地绘图编辑器资源，请重新构建并安装 D板。"); return }
        isReady = false; lastError = nil; overlay.isHidden = false; retry.isHidden = true
        message.stringValue = "正在加载本地编辑器…"; progress.isHidden = false; progress.startAnimation(nil)
        webView.load(URLRequest(url: URL(string: "dboard-drawing://editor/index.html")!))
        readyTimer?.invalidate()
        readyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isReady else { return }
                self.fail("本地编辑器加载超时，请重试。")
            }
        }
    }
    @objc private func reload() {
        guard !document.isUntitled else { return }
        confirmDiscardOrSave { [weak self] accepted in
            guard accepted, let self else { return }
            do {
                // A fresh controller reads external changes as well as resetting the editor.
                let next = try ExcalidrawDocument(url: self.document.url)
                self.documentReload(next)
            } catch { self.present(error.localizedDescription) }
        }
    }
    private func documentReload(_ next: ExcalidrawDocument) {
        // Keep window identity; the manager must not keep a stale document after reload.
        document = next
        setDirty(false); loadEditor()
    }

    func receive(_ message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == "editor",
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            webView.callAsyncJavaScript("window.dboardDrawing.load(scene)", arguments: ["scene": document.original],
                in: nil, in: .page) { [weak self] result in
                    if case .failure(let error) = result {
                        let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                        self?.fail(detail ?? error.localizedDescription)
                    }
                }
        case "loaded":
            snapshot { [weak self] result in
                guard let self else { return }
                do {
                    let data = try result.get()
                    try self.document.recordRestoredSnapshot(data.json)
                    self.isReady = true; self.readyTimer?.invalidate(); self.overlay.isHidden = true
                    self.status.stringValue = "保存到原文件 · ⌘S"; self.setDirty(false)
                } catch { self.fail(error.localizedDescription) }
            }
        case "dirty": setDirty(body["dirty"] as? Bool ?? false)
        case "save": save()
        case "notice": present(body["message"] as? String ?? "")
        case "error": if !isReady { fail(body["message"] as? String ?? "编辑器无法加载") }
        default: break
        }
    }
    struct Snapshot { let json: String; let signature: String }
    func snapshot(_ completion: @escaping (Result<Snapshot, Error>) -> Void) {
        webView.callAsyncJavaScript("return window.dboardDrawing.snapshot()", arguments: [:], in: nil, in: .page) { result in
            completion(result.flatMap { value in
                guard let body = value as? [String: Any], let json = body["json"] as? String, let signature = body["signature"] as? String else {
                    return .failure(ExcalidrawDocument.DocumentError.invalidSnapshot)
                }
                return .success(Snapshot(json: json, signature: signature))
            })
        }
    }
    func save(completion: @escaping (Bool) -> Void = { _ in }) {
        guard isReady, !isSaving else { completion(false); return }
        isSaving = true
        if document.isUntitled {
            status.stringValue = "选择保存位置…"
            let panel = NSSavePanel()
            panel.title = "保存绘图"
            panel.nameFieldStringValue = "未命名.excalidraw"
            panel.allowedContentTypes = [UTType(filenameExtension: "excalidraw") ?? .json]
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { completion(false); return }
                guard response == .OK, let url = panel.url else {
                    self.isSaving = false; self.setDirty(self.isDirty); completion(false); return
                }
                do {
                    let expected = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
                    self.performSave(to: url, expectedData: expected, completion: completion)
                } catch {
                    self.isSaving = false; self.present(error.localizedDescription); completion(false)
                }
            }
        } else { performSave(completion: completion) }
    }
    private func performSave(to destination: URL? = nil, expectedData: Data? = nil, completion: @escaping (Bool) -> Void) {
        status.stringValue = "正在保存…"
        snapshot { [weak self] result in
            guard let self else { completion(false); return }
            do {
                let snapshot = try result.get()
                _ = try self.document.save(snapshot: snapshot.json, to: destination, expectedDestinationData: expectedData)
                self.webView.callAsyncJavaScript("return window.dboardDrawing.saved(signature)", arguments: ["signature": snapshot.signature], in: nil, in: .page) { [weak self] result in
                    guard let self else { completion(false); return }
                    self.isSaving = false
                    if case .failure(let error) = result { self.present(error.localizedDescription); completion(false); return }
                    if case .success(let dirty) = result { self.setDirty(dirty as? Bool ?? true) }
                    self.window.title = self.document.displayName
                    self.window.representedURL = self.document.url
                    self.status.stringValue = self.isDirty ? "有未保存的修改 · ⌘S" : "已保存"
                    completion(!self.isDirty)
                }
            } catch {
                self.isSaving = false; self.lastError = error.localizedDescription
                self.status.stringValue = "保存失败，修改仍保留"; self.present(error.localizedDescription); completion(false)
            }
        }
    }
    private func setDirty(_ dirty: Bool) {
        isDirty = dirty; window.isDocumentEdited = dirty
        if !isSaving { status.stringValue = dirty ? "有未保存的修改 · ⌘S" : (document.isUntitled ? "尚未保存 · ⌘S 选择位置" : "保存到原文件 · ⌘S") }
        window.toolbar?.validateVisibleItems()
    }
    private func fail(_ text: String) {
        lastError = text; readyTimer?.invalidate(); isReady = false
        overlay.isHidden = false; progress.stopAnimation(nil); progress.isHidden = true
        message.stringValue = text; retry.isHidden = false; status.stringValue = "打开失败"
    }
    private func present(_ text: String) {
        let alert = NSAlert(); alert.messageText = "绘图"; alert.informativeText = text; alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
    func confirmDiscardOrSave(_ completion: @escaping (Bool) -> Void) {
        guard !isSaving else { completion(false); return }
        guard isDirty else { completion(true); return }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.messageText = "保存对绘图的修改？"
        alert.informativeText = document.isUntitled ? "保存时可以选择文件名和位置。" : "修改将保存到“" + document.url.lastPathComponent + "”。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "不保存")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if permitsClose || (!isDirty && !isSaving) { return true }
        confirmDiscardOrSave { [weak self] accepted in
            guard accepted, let self else { return }
            self.permitsClose = true; self.window.close()
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; readyTimer?.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dboardDrawing")
        onClose?()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("new"), .init("open"), .init("reload"), .init("fit"), .init("fullscreen"), .flexibleSpace, .init("status"), .init("save")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id.rawValue {
        case "new": item.label = "新建画布"; item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "新建画布"); item.action = #selector(newDrawing)
        case "open": item.label = "打开绘图"; item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "打开绘图"); item.action = #selector(openFile)
        case "reload": item.label = "重新加载"; item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新加载绘图"); item.action = #selector(reload)
        case "fit": item.label = "显示全图"; item.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "显示全图"); item.action = #selector(fit)
        case "fullscreen": item.label = "切换全屏"; item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "切换全屏"); item.action = #selector(toggleFullScreen)
        case "save": item.label = "保存"; item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "保存到原文件"); item.action = #selector(saveFile)
        case "status": item.view = status
        default: return nil
        }
        item.target = self; item.toolTip = item.label
        return item
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier.rawValue {
        case "reload": return !document.isUntitled && !isSaving
        case "save": return isReady && !isSaving
        case "fit": return isReady
        default: return true
        }
    }
    @objc private func newDrawing() { ExcalidrawWindowManager.shared.newDrawing() }
    @objc private func openFile() { ExcalidrawWindowManager.shared.chooseFile() }
    @objc private func fit() { if isReady { webView.evaluateJavaScript("window.dboardDrawing.fit()") } }
    @objc private func saveFile() { save() }
    @objc private func toggleFullScreen() { window.toggleFullScreen(nil) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if url?.scheme == "dboard-drawing", url?.host == "editor" { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, let url, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("绘图编辑器进程已停止。尚未保存的修改无法恢复，请重新打开。") }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}
