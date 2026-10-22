import AppKit
import WebKit

private final class AppReleaseWindowDragHandle: NSVisualEffectView {
    var title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .withinWindow
        state = .active
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (title as NSString).draw(
            in: bounds,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class AppReleaseWebHost: NSViewController {
    private var webView: WKWebView
    private var webViewConstraints: [NSLayoutConstraint] = []
    private let webViewContainer = NSView()
    private let dragHandle: AppReleaseWindowDragHandle

    init(webView: WKWebView, title: String) {
        self.webView = webView
        self.dragHandle = AppReleaseWindowDragHandle(title: title)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String) {
        dragHandle.title = title
        dragHandle.needsDisplay = true
    }

    func setWebView(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        NSLayoutConstraint.deactivate(webViewConstraints)
        webViewConstraints = []
        self.webView.removeFromSuperview()
        self.webView = webView
        guard isViewLoaded else { return }
        addWebViewConstraints()
    }

    override func loadView() {
        let view = NSView()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        webViewContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webViewContainer)
        view.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dragHandle.topAnchor.constraint(equalTo: view.topAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: 32),
            webViewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webViewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webViewContainer.topAnchor.constraint(equalTo: dragHandle.bottomAnchor),
            webViewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
        addWebViewConstraints()
    }

    private func addWebViewConstraints() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webViewContainer.addSubview(webView)
        webViewConstraints = [
            webView.leadingAnchor.constraint(equalTo: webViewContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webViewContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webViewContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webViewContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(webViewConstraints)
    }
}

final class AppReleaseWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let shared = AppReleaseWindowController()

    private static let diagnosticScript = #"""
    (() => {
      if (location.hostname !== 'audi.tmallyc.com') return;
      const report = (detail) => {
        try { window.webkit.messageHandlers.dboardDiag.postMessage(detail); } catch {}
      };
      const hasSession = document.cookie.split(';').some((part) => part.trim().startsWith('ac-session-id='));
      report({ kind: 'cookie', visible: hasSession });

      const targets = new Set([
        '/superapi/auth/currentUserInfo',
        '/superapi/auth/menuServiceFacade/initSystemAndGetSystemName',
        '/superapi/auth/selectCurrentUserMenusByCondition',
      ]);
      const proto = XMLHttpRequest.prototype;
      const originalOpen = proto.open;
      const originalSend = proto.send;
      proto.open = function(method, url, ...rest) {
        try {
          const parsed = new URL(String(url), location.href);
          this.__dboardDiagRequest = { host: parsed.host, path: parsed.pathname };
        } catch {}
        return originalOpen.call(this, method, url, ...rest);
      };
      proto.send = function(...args) {
        const request = this.__dboardDiagRequest;
        if (request && targets.has(request.path)) {
          this.addEventListener('loadend', () => {
            let payload = null;
            try { payload = JSON.parse(this.responseText); } catch {}
            const info = payload && payload.info;
            const result = {
              kind: 'gateway', host: request.host, path: request.path,
              httpStatus: this.status, code: payload && payload.code,
            };
            if (request.path.endsWith('/auth/currentUserInfo')) {
              result.accountPresent = Boolean(info && info.account);
              result.audiLedgerPresent = Boolean(info && info.systemLedgerMap && info.systemLedgerMap.audi);
            } else if (request.path.endsWith('/initSystemAndGetSystemName')) {
              result.resourceKeyPresent = Boolean(info && info.resourceKey);
            } else if (Array.isArray(info)) {
              const hasHome = (items) => items.some((item) => {
                let path = item.menuUrl || '';
                try { path = new URL(path, location.href).pathname; } catch {}
                return (item.resourceType === 1 && path.split('/').filter(Boolean).join('/') === 'home')
                  || hasHome(item.children || []);
              });
              result.menuCount = info.length;
              result.homeMenuPresent = hasHome(info);
            } else {
              result.menuPayloadIsArray = false;
            }
            report(result);
          }, { once: true });
        }
        return originalSend.apply(this, args);
      };
    })();
    """#
    private enum Page: Hashable {
        case appRelease
        case logs
        case home

        var url: URL {
            switch self {
            case .appRelease: URL(string: "https://audi.tmallyc.com/app-release")!
            case .logs: URL(string: "https://audi.tmallyc.com/logs-hist")!
            case .home: URL(string: "https://audi.tmallyc.com/")!
            }
        }

        var title: String {
            switch self {
            case .appRelease: "应用发布台 · audi"
            case .logs: "Audi 日志"
            case .home: "Audi 首页"
            }
        }
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var webViews: [Page: WKWebView] = [:]
    private var webHost: AppReleaseWebHost?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var page: Page = .appRelease
    private var loadFailed = false
    private var chromeSession: HTTPCookie?
    private static let diagnosticQueue = DispatchQueue(label: "dboard.audi-diagnostic")

    func recordDiagnostic(_ message: String) {
        Self.diagnosticQueue.async {
            let url = URL(fileURLWithPath: "/tmp/dboard-audi-diagnostic.log")
            let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: url.path, contents: data)
            }
        }
    }

    func toggle() { toggle(.appRelease) }

    func toggleLogs() { toggle(.logs) }

    func toggleHome() { toggle(.home) }

    private func toggle(_ target: Page) {
        if let window, window.isVisible, page == target {
            dismissWindow()
        } else {
            show(target)
        }
    }

    func show() { show(.appRelease) }

    func showLogs() { show(.logs) }

    private func show(_ target: Page) {
        let pageChanged = page != target
        page = target
        if let window {
            if pageChanged {
                window.title = target.title
                webHost?.setTitle(target.title)
                loadFailed = false
                if let retainedWebView = webViews[target] {
                    webView = retainedWebView
                    webHost?.setWebView(retainedWebView)
                } else {
                    let newWebView = makeWebView()
                    webViews[target] = newWebView
                    webView = newWebView
                    webHost?.setWebView(newWebView)
                    if let chromeSession { install(chromeSession, into: newWebView) }
                    else { loadPageOrWait() }
                }
            } else if loadFailed, let chromeSession {
                install(chromeSession, into: webView)
            }
            centerWindowOnMouseScreen(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            installDismissMonitors()
            return
        }

        page = target
        let webView = makeWebView()
        webViews[target] = webView
        let webHost = AppReleaseWebHost(webView: webView, title: target.title)
        let window = NSWindow(contentViewController: webHost)
        window.title = target.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.standardWindowButton(.closeButton)?.target = self
        window.standardWindowButton(.closeButton)?.action = #selector(dismissWindow)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.setContentSize(NSSize(width: 1200, height: 840))
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("DBoardAppReleaseWebWindow")
        centerWindowOnMouseScreen(window)

        self.webView = webView
        self.webHost = webHost
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installDismissMonitors()
        if let chromeSession { install(chromeSession, into: webView) }
        else { loadPageOrWait() }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let contentController = WKUserContentController()
        contentController.add(self, name: "dboardDiag")
        contentController.addUserScript(WKUserScript(
            source: Self.diagnosticScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        return webView
    }

    private func loadPageOrWait() {
        guard let webView else { return }
        let targetPage = page
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            let session = cookies.first {
                $0.name == "ac-session-id" &&
                ($0.domain == "audi.tmallyc.com" || $0.domain == ".tmallyc.com" || $0.domain == "tmallyc.com") &&
                ($0.expiresDate.map { $0 > Date() } ?? true)
            }
            DispatchQueue.main.async {
                guard let self, self.chromeSession == nil else { return }
                guard let session else {
                    self.showWaitingPage(in: webView)
                    return
                }
                self.chromeSession = session
                self.recordDiagnostic("cookie restored from webview store domain=\(session.domain) httpOnly=\(session.isHTTPOnly)")
                self.loadPage(targetPage, in: webView)
            }
        }
    }

    @objc private func dismissWindow() {
        window?.orderOut(nil)
        teardownDismissMonitors()
    }

    private func installDismissMonitors() {
        teardownDismissMonitors()
        let clickEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickEvents) { [weak self] _ in
            DispatchQueue.main.async { self?.dismissIfClickedOutside() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clickEvents) { [weak self] event in
            self?.dismissIfClickedOutside()
            return event
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismissWindow()
        }
    }

    private func dismissIfClickedOutside() {
        guard let window, window.isVisible, !window.frame.contains(NSEvent.mouseLocation) else { return }
        DispatchQueue.main.async { self.dismissWindow() }
    }

    private func teardownDismissMonitors() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor); outsideClickMonitor = nil }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor); localClickMonitor = nil }
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            resignActiveObserver = nil
        }
    }

    func receiveChromeSession(_ cookie: HTTPCookie) {
        BizMapBoardWindowController.shared.receiveAudiSession(cookie)
        recordDiagnostic("cookie received domain=\(cookie.domain) path=\(cookie.path) secure=\(cookie.isSecure) httpOnly=\(cookie.isHTTPOnly)")
        NSLog("DBoard AudiDiag cookie received domain=%@ path=%@ secure=%@ httpOnly=%@",
              cookie.domain, cookie.path, cookie.isSecure ? "yes" : "no", cookie.isHTTPOnly ? "yes" : "no")
        let hadSession = chromeSession != nil
        let changed = chromeSession?.value != cookie.value
        chromeSession = cookie
        if changed || loadFailed {
            let reloadPage = !hadSession || loadFailed
            recordDiagnostic("cookie update changed=\(changed) reloadPage=\(reloadPage)")
            install(cookie, into: webView, reloadPage: reloadPage, reloadAllPages: !hadSession)
        }
    }

    func clearChromeSession() {
        recordDiagnostic("cookie clear requested")
        chromeSession = nil
        guard let webView else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            for cookie in cookies where cookie.name == "ac-session-id" &&
                (cookie.domain == "audi.tmallyc.com" || cookie.domain == ".tmallyc.com") {
                store.delete(cookie)
            }
            DispatchQueue.main.async { self?.showWaitingPage() }
        }
    }

    private func install(
        _ cookie: HTTPCookie,
        into webView: WKWebView?,
        reloadPage: Bool = true,
        reloadAllPages: Bool = false
    ) {
        guard let webView else { return }
        let targetPage = page
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            let existing = cookies.filter {
                $0.name == "ac-session-id" &&
                ($0.domain == "audi.tmallyc.com" || $0.domain == ".tmallyc.com" || $0.domain == "tmallyc.com")
            }
            let deletions = DispatchGroup()
            for oldCookie in existing {
                deletions.enter()
                store.delete(oldCookie) { deletions.leave() }
            }
            deletions.notify(queue: .main) {
                store.setCookie(cookie) {
                    store.getAllCookies { cookies in
                        let stored = cookies.first {
                            $0.name == "ac-session-id" &&
                            ($0.domain == "audi.tmallyc.com" || $0.domain == ".tmallyc.com" || $0.domain == "tmallyc.com")
                        }
                        let domain = stored?.domain ?? "none"
                        let path = stored?.path ?? "none"
                        self?.recordDiagnostic("cookie store present=\(stored == nil ? "no" : "yes") httpOnly=\(stored?.isHTTPOnly == true ? "yes" : "no") domain=\(domain) path=\(path) reloadPage=\(reloadPage)")
                        NSLog("DBoard AudiDiag cookie store present=%@ httpOnly=%@",
                              stored == nil ? "no" : "yes", stored?.isHTTPOnly == true ? "yes" : "no")
                        if reloadAllPages {
                            DispatchQueue.main.async {
                                self?.webViews.forEach { self?.loadPage($0.key, in: $0.value) }
                            }
                        } else if reloadPage {
                            DispatchQueue.main.async { self?.loadPage(targetPage, in: webView) }
                        }
                    }
                }
            }
        }
    }

    private func showWaitingPage() {
        guard let webView else { return }
        showWaitingPage(in: webView)
    }

    private func showWaitingPage(in webView: WKWebView) {
        webView.loadHTMLString("""
        <html><meta charset="utf-8"><body style="font:16px -apple-system;padding:48px;color:#334155">
        <h2>等待 Chrome 登录态</h2>
        <p>请在 Chrome 登录 audi.tmallyc.com，并在 chrome://extensions 重新加载 DBoard Cookie Bridge 扩展。</p>
        <p>扩展会自动将当前会话传给这个窗口；此处不会单独登录，以免挤掉 Chrome。</p>
        </body></html>
        """, baseURL: nil)
    }

    private func loadPage() {
        guard let webView else { return }
        loadPage(page, in: webView)
    }

    private func loadPage(_ page: Page, in webView: WKWebView) {
        webView.load(URLRequest(url: page.url, cachePolicy: .reloadRevalidatingCacheData))
    }

    // SSO 是站点的正常重定向，不能因域名变化而取消；只将用户点击的站外链接外开。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.host == "sso-tmyc.tmallyc.com" {
            decisionHandler(.cancel)
            loadFailed = true
            showWaitingPage()
            return
        }
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           !isAppOrSSOHost(url.host) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // target=_blank 的应用/SSO 页面在当前 WebView 打开，避免登录流程被拆到外部窗口。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if isAppOrSSOHost(url.host) { webView.load(navigationAction.request) }
        else { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFailed = webView.url?.host != "audi.tmallyc.com"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.securityOrigin.host == "audi.tmallyc.com",
              let data = message.body as? [String: Any],
              let kind = data["kind"] as? String else { return }
        if kind == "cookie" {
            let visible = (data["visible"] as? Bool) == true
            recordDiagnostic("document.cookie ac-session-id visible=\(visible ? "yes" : "no")")
            NSLog("DBoard AudiDiag document.cookie ac-session-id visible=%@", visible ? "yes" : "no")
            return
        }
        guard kind == "gateway",
              let host = data["host"] as? String,
              ["pre-i0-superapiplus.tmallyc-inc.net", "api-tmyc.tmallyc.com"].contains(host),
              let path = data["path"] as? String else { return }
        let status = (data["httpStatus"] as? Int).map(String.init) ?? "none"
        let code = data["code"].map(String.init(describing:)) ?? "none"
        let details = ["accountPresent", "audiLedgerPresent", "resourceKeyPresent", "homeMenuPresent", "menuPayloadIsArray"]
            .compactMap { key in (data[key] as? Bool).map { "\(key)=\($0)" } }
        let menuCount = (data["menuCount"] as? Int).map { " menuCount=\($0)" } ?? ""
        recordDiagnostic("gateway host=\(host) path=\(path) http=\(status) code=\(code)\(menuCount) \(details.joined(separator: " "))")
        NSLog("DBoard AudiDiag gateway host=%@ path=%@ http=%@ code=%@%@ %@",
              host, path, status, code, menuCount, details.joined(separator: " "))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadFailed = true
        NSLog("DBoard: AppRelease 页面加载失败 %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed = true
        NSLog("DBoard: AppRelease 页面加载失败 %@", error.localizedDescription)
    }

    private func isAppOrSSOHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "audi.tmallyc.com" || host == "sso-tmyc.tmallyc.com"
    }
}
