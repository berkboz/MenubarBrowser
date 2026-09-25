import AppKit
import SwiftUI
import Combine
import ServiceManagement

// Perch is a browser that lives in the menu bar. Click its icon, or press
// ⌥Space anywhere, and a page drops down; press Escape and it's gone, and
// you're back where you were.

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let browser = Browser()
    let prefs = Prefs.shared
    private(set) var panel: PanelController!
    private var status: NSStatusItem!
    private var hotKey: HotKey?
    private var commands: Commands!
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        prefs.look.apply()
        Blocker.shared.prepare()
        browser.restore()

        panel = PanelController(browser: browser)
        commands = Commands(browser: browser, panel: panel)
        NSApp.mainMenu = commands.mainMenu()
        makeStatusItem()

        prefs.$hotKey
            .receive(on: RunLoop.main)
            .sink { [weak self] combo in self?.register(combo) }
            .store(in: &bag)

        prefs.$blockAds
            .dropFirst()
            .sink { [weak self] on in self?.applyBlocker(on) }
            .store(in: &bag)

        // `--show [address]` opens the panel at launch (used to screenshot builds).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show") {
            if args.count > i + 1, let url = URL(string: args[i + 1]), url.scheme != nil {
                browser.open(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.panel.show() }
        } else if !prefs.welcomed {
            // First launch: show the panel so there's no wondering where it went.
            prefs.welcomed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.panel.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        browser.save()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    /// Links from other apps, when Perch is the default browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { browser.open(url, in: .newTab(focus: true)) }
        panel.show()
    }

    // MARK: Menu bar icon

    private func makeStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.autosaveName = "Perch"
        guard let button = status.button else { return }
        button.image = StatusGlyph.image
        button.image?.accessibilityDescription = "Perch"
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Perch"
        panel.anchor = button
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            // ⌥-click: straight to a fresh tab.
            browser.newTab()
            panel.show()
        } else {
            panel.toggle()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Tab", action: #selector(Commands.newTab), keyEquivalent: "").target = commands
        menu.addItem(withTitle: "New Private Tab", action: #selector(Commands.newPrivateTab), keyEquivalent: "").target = commands
        menu.addItem(.separator())
        let pin = menu.addItem(withTitle: "Keep Open", action: #selector(Commands.togglePin), keyEquivalent: "")
        pin.target = commands
        pin.state = prefs.pinned ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(Commands.openSettings), keyEquivalent: ",").target = commands
        menu.addItem(withTitle: "Quit Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        status.button?.performClick(nil)
        status.menu = nil
    }

    // MARK: Hot key

    private func register(_ combo: KeyCombo?) {
        hotKey = nil
        guard let combo else { return }
        hotKey = HotKey(combo) { [weak self] in self?.panel.toggle() }
        if hotKey == nil {
            NSLog("Perch: \(combo.label) is taken by another app")
        }
    }

    /// Settings suspends the hot key while it records a new one, so pressing
    /// the old one doesn't close the window being typed into.
    func suspendHotKey(_ suspend: Bool) {
        if suspend { hotKey = nil } else { register(prefs.hotKey) }
    }

    private func applyBlocker(_ on: Bool) {
        for tab in browser.tabs {
            let controller = tab.webView.configuration.userContentController
            if on {
                Blocker.shared.whenReady { controller.add($0) }
            } else {
                controller.removeAllContentRuleLists()
            }
        }
        browser.reload()
    }
}

// MARK: - Menu bar glyph

/// The bird from the app icon, as a template image so the menu bar tints it
/// (Icon/MenuBarIcon*.png, copied into the app by build.sh). Running outside
/// an app bundle, a little window drawn in code stands in.
enum StatusGlyph {
    static let image: NSImage = {
        if let bird = Bundle.main.image(forResource: "MenuBarIcon") {
            bird.size = NSSize(width: 18, height: 18)
            bird.isTemplate = true
            return bird
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: NSRect(x: 2.25, y: 2.75, width: 13.5, height: 12.5),
                                    xRadius: 3.6, yRadius: 3.6)
            body.lineWidth = 1.5
            body.stroke()
            let bar = NSBezierPath(roundedRect: NSRect(x: 5.25, y: 10.4, width: 7.5, height: 2),
                                   xRadius: 1, yRadius: 1)
            bar.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

// MARK: - Launch at login

enum LoginItem {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Perch: login item: \(error)")
        }
    }
}
