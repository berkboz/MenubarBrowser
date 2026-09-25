import AppKit
import WebKit

/// One page and everything it knows about itself. The web view lives as long
/// as the tab does, so switching tabs never reloads anything.
final class Tab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool
    let webView: PerchWebView
    weak var browser: Browser?

    @Published var title = ""
    @Published var url: URL?
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var secure = false
    @Published var snapshot: NSImage?
    @Published var failure: Failure?

    /// An address restored from last time, loaded only when the tab is first
    /// looked at, so a long session costs nothing at launch.
    var pending: URL?
    /// Set by "Request Desktop Site" / "Request Mobile Site"; nil follows the setting.
    var layoutOverride: Agent?

    private var observers: [NSKeyValueObservation] = []

    struct Failure: Equatable {
        let url: URL?
        let message: String
        let offline: Bool
    }

    var isBlank: Bool { url == nil && pending == nil && !loading }
    var host: String { (url ?? pending)?.displayHost ?? "" }
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let u = url ?? pending { return u.displayHost }
        return isPrivate ? "Private Tab" : "Start Page"
    }

    init(browser: Browser, isPrivate: Bool, configuration: WKWebViewConfiguration? = nil) {
        self.browser = browser
        self.isPrivate = isPrivate
        let config = configuration ?? Tab.configuration(isPrivate: isPrivate)
        webView = PerchWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = .clear
        applyAgent()
        observe()
        if Prefs.shared.blockAds {
            Blocker.shared.whenReady { [weak self] list in
                guard let self, Prefs.shared.blockAds else { return }
                self.webView.configuration.userContentController.add(list)
            }
        }
    }

    deinit {
        observers.forEach { $0.invalidate() }
    }

    private static var privateStore = WKWebsiteDataStore.nonPersistent()

    static func configuration(isPrivate: Bool) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = isPrivate ? privateStore : .default()
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.allowsAirPlayForMediaPlayback = true
        c.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        return c
    }

    /// All private tabs share one store; closing the last forgets everything.
    static func forgetPrivateData() {
        privateStore = .nonPersistent()
    }

    private func observe() {
        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                guard let self else { return }
                self.title = wv.title ?? ""
                if !self.isPrivate, let url = wv.url { History.shared.retitle(url, title: self.title) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                guard let self, let url = wv.url else { return }
                self.url = url
                self.secure = url.scheme == "https"
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                self?.progress = wv.estimatedProgress
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                self?.loading = wv.isLoading
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                self?.canGoBack = wv.canGoBack
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                self?.canGoForward = wv.canGoForward
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] wv, _ in
                guard let self else { return }
                self.secure = wv.url?.scheme == "https" && wv.hasOnlySecureContent
            },
        ]
    }

    // MARK: Actions

    func load(_ url: URL) {
        pending = nil
        failure = nil
        self.url = url
        applyAgent()
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Loads a restored address the first time the tab is shown.
    func wake() {
        if let pending { load(pending) }
    }

    func reload() {
        failure = nil
        if let pending { load(pending); return }
        if webView.url == nil, let url { load(url); return }
        webView.reload()
    }

    func stop() { webView.stopLoading() }
    func goBack() { failure = nil; webView.goBack() }
    func goForward() { failure = nil; webView.goForward() }

    func zoom(_ step: Int) {
        let steps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        guard step != 0 else { webView.pageZoom = 1; return }
        let now = webView.pageZoom
        let i = steps.firstIndex(where: { $0 >= now - 0.001 }) ?? 5
        let next = min(max(i + step, 0), steps.count - 1)
        webView.pageZoom = steps[next]
    }

    func captureSnapshot() {
        guard url != nil, webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 480
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }

    /// Which layout to ask for: a menu bar panel is usually phone-width, and
    /// pages look far better in their phone layout there.
    var wantsMobile: Bool {
        switch layoutOverride ?? Prefs.shared.agent {
        case .mobile: return true
        case .desktop: return false
        case .automatic: return (browser?.panelWidth ?? 400) < Metrics.mobileBreak
        }
    }

    func applyAgent() {
        let agent = wantsMobile ? Agent.iPhone : Agent.mac
        if webView.customUserAgent != agent { webView.customUserAgent = agent }
    }

    /// Flips between phone and desktop layouts and reloads to show it.
    func toggleLayout() {
        layoutOverride = wantsMobile ? .desktop : .mobile
        applyAgent()
        if let url = webView.url ?? url { load(url) }
    }

    private func fetchIcon() {
        guard let host = webView.url?.host else { return }
        if Icons.shared.byHost[host] != nil { return }
        webView.evaluateJavaScript(Icons.finder) { result, _ in
            guard let href = result as? String, let url = URL(string: href) else { return }
            Icons.shared.fetch(host: host, from: url,
                               fallback: URL(string: "https://\(host)/favicon.ico"))
        }
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }

        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        // Anything that isn't a web page belongs to the app that owns it:
        // mailto: to Mail, facetime: to FaceTime, an App Store link to the store.
        let scheme = url.scheme?.lowercased() ?? ""
        let web = ["http", "https", "about", "data", "blob", "file", "javascript"]
        if !web.contains(scheme) {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated || action.sourceFrame.isMainFrame {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // ⌘-click and a middle click open behind; ⇧⌘-click opens in front.
        if action.navigationType == .linkActivated,
           action.targetFrame?.isMainFrame ?? true,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            decisionHandler(.cancel)
            browser?.open(url, in: .newTab(focus: action.modifierFlags.contains(.shift)), privately: isPrivate)
            return
        }

        if action.targetFrame?.isMainFrame ?? false { applyAgent() }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = browser?.downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = browser?.downloads
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isPrivate, let url = webView.url {
            History.shared.record(url, title: webView.title ?? "")
        }
        fetchIcon()
        browser?.saveSoon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let e = error as NSError
        // Cancelled, or handed over to a download: nothing went wrong.
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        let offline = e.domain == NSURLErrorDomain &&
            [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(e.code)
        failure = Failure(url: failing, message: e.localizedDescription, offline: offline)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Windows, dialogs, files

extension Tab: WKUIDelegate {
    /// target="_blank" and window.open: a new tab, built on the configuration
    /// WebKit hands over so the opener keeps its link to it.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let browser else { return nil }
        let tab = browser.adopt(configuration: configuration, privately: isPrivate)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = dialog(message, frame: frame)
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = dialog(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = dialog(prompt, frame: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        browser?.holdOpen += 1
        panel.begin { [weak self] response in
            self?.browser?.holdOpen -= 1
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    private func dialog(_ text: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = text
        return alert
    }

    /// Alerts hang from the panel as sheets, so they arrive where the page is.
    private func present(_ alert: NSAlert, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: then)
        } else {
            then(alert.runModal())
        }
    }
}

// MARK: - The web view itself

/// WKWebView with Perch's words in its context menu: there are no windows
/// here, only tabs.
final class PerchWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = "Open Frame in New Tab"
            default: break
            }
        }
    }
}
