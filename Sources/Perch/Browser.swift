import AppKit
import WebKit
import SwiftUI

/// The tabs, which one is showing, and everything the panel can be asked to do.
final class Browser: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var active: Tab?
    @Published var overview = false
    @Published var finding = false
    @Published var toast: Toast?
    /// Bumped to ask the address field to take the keyboard.
    @Published var focusRequest = 0
    @Published var panelWidth: CGFloat = Prefs.shared.size.width

    /// While above zero, the panel stays up even when Perch loses focus: a
    /// file picker or a sheet is open on its behalf.
    var holdOpen = 0
    let downloads = Downloads()
    weak var panel: PanelController?

    private var closed: [URL] = []
    private var saveWork: DispatchWorkItem?

    enum Placement {
        case current
        case newTab(focus: Bool)
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var symbol: String
        var text: String
        var actionTitle: String?
        var action: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    init() {
        downloads.browser = self
    }

    var hasPrivateTabs: Bool { tabs.contains { $0.isPrivate } }
    var canReopen: Bool { !closed.isEmpty }

    // MARK: Tabs

    @discardableResult
    func newTab(privately: Bool = false, focus: Bool = true) -> Tab {
        let tab = Tab(browser: self, isPrivate: privately)
        insert(tab)
        if focus {
            select(tab)
            overview = false
            focusField()
        }
        return tab
    }

    /// A tab for a web view WebKit asked for (window.open, target="_blank").
    func adopt(configuration: WKWebViewConfiguration, privately: Bool) -> Tab {
        let tab = Tab(browser: self, isPrivate: privately, configuration: configuration)
        insert(tab)
        select(tab)
        return tab
    }

    private func insert(_ tab: Tab) {
        if let active, let i = tabs.firstIndex(of: active) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
    }

    func select(_ tab: Tab) {
        guard tabs.contains(tab) else { return }
        if active !== tab {
            active?.captureSnapshot()
            finding = false
        }
        active = tab
        tab.wake()
        saveSoon()
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func selectLast() {
        if let last = tabs.last { select(last) }
    }

    func cycle(_ step: Int) {
        guard let active, let i = tabs.firstIndex(of: active), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(of: tab) else { return }
        if !tab.isPrivate, let url = tab.url ?? tab.pending { closed.append(url) }
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        tabs.remove(at: i)
        if !hasPrivateTabs && tab.isPrivate { Tab.forgetPrivateData() }
        if active === tab {
            active = nil
            if tabs.isEmpty {
                newTab()
            } else {
                select(tabs[min(i, tabs.count - 1)])
            }
        }
        saveSoon()
    }

    func closeActive() {
        if let active { close(active) }
    }

    func closeOthers(than keep: Tab) {
        for tab in tabs where tab !== keep { close(tab) }
    }

    func reopen() {
        guard let url = closed.popLast() else { return }
        open(url, in: .newTab(focus: true))
    }

    // MARK: Going places

    func open(_ url: URL, in placement: Placement = .current, privately: Bool? = nil) {
        switch placement {
        case .current:
            let tab = active ?? newTab(focus: false)
            select(tab)
            tab.load(url)
            overview = false
        case .newTab(let focus):
            let tab = Tab(browser: self, isPrivate: privately ?? active?.isPrivate ?? false)
            insert(tab)
            tab.load(url)
            if focus {
                select(tab)
                overview = false
            } else {
                flash(symbol: "square.on.square", text: "Opened in a new tab")
            }
        }
        saveSoon()
    }

    /// What the address field does with whatever was typed: an address if it
    /// looks like one, a search if it doesn't.
    func submit(_ text: String, newTab: Bool = false) {
        guard let url = Self.resolve(text) else { return }
        open(url, in: newTab ? .newTab(focus: true) : .current)
        focusPage()
    }

    static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        for prefix in ["http://", "https://", "file://", "about:", "data:"] where lower.hasPrefix(prefix) {
            if let url = URL(string: text) { return url }
        }
        if text.hasPrefix("/") || text.hasPrefix("~/") {
            let path = (text as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }

        let looksLikeAddress: Bool = {
            guard !text.contains(" ") else { return false }
            let hostPart = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
            let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
            if host == "localhost" { return true }
            if host.split(separator: ".").count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
            guard let dot = host.lastIndex(of: ".") else { return false }
            let tld = host[host.index(after: dot)...]
            return tld.count >= 2 && tld.allSatisfy(\.isLetter)
        }()

        if looksLikeAddress {
            let local = lower.hasPrefix("localhost") || lower.first?.isNumber == true
            return URL(string: (local ? "http://" : "https://") + text)
        }
        return Prefs.shared.engine.search(text)
    }

    // MARK: The page

    func reload() { active?.reload() }
    func goBack() { active?.goBack() }
    func goForward() { active?.goForward() }
    func zoom(_ step: Int) { active?.zoom(step) }

    func goHome() {
        guard let active else { return }
        if active.url == nil { return }
        // A fresh tab in place of this one, so Back still works in the old one
        // if it's reopened.
        let fresh = Tab(browser: self, isPrivate: active.isPrivate)
        if let i = tabs.firstIndex(of: active) {
            if let url = active.url { closed.append(url) }
            tabs[i] = fresh
            active.webView.removeFromSuperview()
            self.active = fresh
        }
        focusField()
        saveSoon()
    }

    func copyLink() {
        guard let url = active?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        flash(symbol: "link", text: "Link copied")
    }

    func openInDefaultBrowser() {
        guard let url = active?.url else { return }
        let others = NSWorkspace.shared.urlsForApplications(toOpen: url)
            .filter { $0.lastPathComponent != Bundle.main.bundleURL.lastPathComponent }
        let config = NSWorkspace.OpenConfiguration()
        if let target = NSWorkspace.shared.urlForApplication(toOpen: url),
           target != Bundle.main.bundleURL {
            NSWorkspace.shared.open([url], withApplicationAt: target, configuration: config)
        } else if let first = others.first {
            NSWorkspace.shared.open([url], withApplicationAt: first, configuration: config)
        }
        panel?.hide()
    }

    func toggleFavorite() {
        guard let tab = active, let url = tab.url else { return }
        let was = History.shared.isFavorite(url)
        History.shared.toggleFavorite(url, title: tab.title)
        flash(symbol: was ? "star.slash" : "star.fill", text: was ? "Removed from Favorites" : "Added to Favorites")
        objectWillChange.send()
    }

    func toggleLayout() {
        guard let tab = active, tab.url != nil else { return }
        tab.toggleLayout()
        flash(symbol: tab.wantsMobile ? "iphone" : "macbook",
              text: tab.wantsMobile ? "Mobile site" : "Desktop site")
    }

    func showOverview() {
        active?.captureSnapshot()
        withAnimation(Motion.glide) { overview.toggle() }
    }

    // MARK: Find

    func openFind() {
        guard active?.url != nil else { return }
        overview = false
        finding = true
    }

    func find(_ text: String, backwards: Bool = false, done: @escaping (Bool) -> Void) {
        guard let web = active?.webView, !text.isEmpty else { done(true); return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        web.find(text, configuration: config) { result in done(result.matchFound) }
    }

    // MARK: Focus

    func focusField() {
        focusRequest += 1
    }

    func focusPage() {
        guard let web = active?.webView else { return }
        DispatchQueue.main.async { web.window?.makeFirstResponder(web) }
    }

    func panelDidShow() {
        if let active, active.isBlank { focusField() }
    }

    func panelResized(width: CGFloat) {
        panelWidth = width
    }

    // MARK: Toasts

    func flash(symbol: String, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let toast = Toast(symbol: symbol, text: text, actionTitle: actionTitle, action: action)
        withAnimation(Motion.settle) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 2.2 : 5)) { [weak self] in
            guard let self, self.toast == toast else { return }
            withAnimation(Motion.settle) { self.toast = nil }
        }
    }

    // MARK: Session

    private struct Session: Codable {
        var urls: [String]
        var active: Int
    }

    func restore() {
        let session = Storage.load(Session.self, from: "session.json")
        for string in session?.urls ?? [] {
            guard let url = URL(string: string) else { continue }
            let tab = Tab(browser: self, isPrivate: false)
            tab.pending = url
            tabs.append(tab)
        }
        if tabs.isEmpty {
            newTab(focus: false)
        }
        let i = min(max(session?.active ?? 0, 0), tabs.count - 1)
        active = tabs[i]
    }

    /// Wakes the active tab once the panel is actually showing, so nothing
    /// loads at launch.
    func wakeActive() {
        active?.wake()
    }

    func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func save() {
        let kept = tabs.filter { !$0.isPrivate }
        let urls = kept.compactMap { ($0.url ?? $0.pending)?.absoluteString }
        let index = active.flatMap { a in kept.filter { $0.url != nil || $0.pending != nil }.firstIndex(of: a) } ?? 0
        Storage.save(Session(urls: urls, active: index), to: "session.json")
        History.shared.flush()
    }
}

// MARK: - Downloads

/// Files go to Downloads, with a toast to say so and a button to show them.
final class Downloads: NSObject, WKDownloadDelegate {
    weak var browser: Browser?
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = Self.unique(folder.appendingPathComponent(suggestedFilename))
        destinations[ObjectIdentifier(download)] = url
        browser?.flash(symbol: "arrow.down.circle", text: "Downloading \(url.lastPathComponent)")
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Makes the Downloads stack in the Dock bounce, as Safari's do.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                     object: url.path)
        browser?.flash(symbol: "checkmark.circle.fill", text: url.lastPathComponent, actionTitle: "Show") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let name = destinations.removeValue(forKey: ObjectIdentifier(download))?.lastPathComponent ?? "Download"
        browser?.flash(symbol: "exclamationmark.triangle.fill", text: "\(name) failed")
    }

    private static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for n in 2... {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
