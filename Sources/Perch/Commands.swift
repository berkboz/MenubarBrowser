import AppKit
import SwiftUI

/// The menu bar Perch never shows. An accessory app has no menus on screen,
/// but its main menu still carries every keyboard shortcut — and without an
/// Edit menu, ⌘C and ⌘V wouldn't work in a single text field.
final class Commands: NSObject {
    let browser: Browser
    let panel: PanelController
    private var settings: NSWindow?
    /// For the views, which need the "⋯" menu and Settings.
    static weak var current: Commands?

    init(browser: Browser, panel: PanelController) {
        self.browser = browser
        self.panel = panel
        super.init()
        Commands.current = self
    }

    /// The "⋯" menu, dropped from just under its button. `frame` is the
    /// button's frame in the panel, measured from its top left.
    func popUpMore(below frame: CGRect) {
        guard let content = panel.panel.contentView else { return }
        let menu = moreMenu()
        let point = NSPoint(x: frame.minX, y: content.bounds.height - frame.maxY - 4)
        menu.popUp(positioning: nil, at: point, in: content)
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        let tab = browser.active
        let hasPage = tab?.url != nil

        menu.addItem(item("New Tab", #selector(newTab), "t"))
        menu.addItem(item("New Private Tab", #selector(newPrivateTab), "n", [.command, .shift]))
        menu.addItem(.separator())

        if hasPage {
            let fav = History.shared.isFavorite(tab?.url)
            menu.addItem(item(fav ? "Remove from Favorites" : "Add to Favorites", #selector(favorite), "d"))
            menu.addItem(item("Copy Link", #selector(copyLink), "c", [.command, .shift]))
            if let url = tab?.url {
                menu.addItem(NSSharingServicePicker(items: [url]).standardShareMenuItem)
            }
            menu.addItem(item("Open in Default Browser", #selector(openElsewhere)))
            menu.addItem(.separator())
            menu.addItem(item("Find on Page…", #selector(find), "f"))
            let wantsMobile = tab?.wantsMobile ?? true
            menu.addItem(item(wantsMobile ? "Request Desktop Site" : "Request Mobile Site",
                              #selector(toggleLayout), "d", [.command, .option]))
            let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
            zoom.submenu = {
                let m = NSMenu()
                m.addItem(item("Zoom In", #selector(zoomIn), "+"))
                m.addItem(item("Zoom Out", #selector(zoomOut), "-"))
                m.addItem(item("Actual Size", #selector(zoomReset), "0"))
                return m
            }()
            menu.addItem(zoom)
            menu.addItem(.separator())
        }

        let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        size.submenu = {
            let m = NSMenu()
            let selectors = [#selector(sizePhone), #selector(sizeTablet), #selector(sizeDesktop)]
            for (i, preset) in SizePreset.allCases.enumerated() {
                let entry = item(preset.title, selectors[i], "\(i + 1)", [.command, .control])
                entry.image = NSImage(systemSymbolName: preset.symbol, accessibilityDescription: nil)
                m.addItem(entry)
            }
            return m
        }()
        menu.addItem(size)
        menu.addItem(item("Keep Open", #selector(togglePin), "p", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        let quit = NSMenuItem(title: "Quit Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc func openElsewhere() { browser.openInDefaultBrowser() }

    func mainMenu() -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Perch", [
            item("About Perch", #selector(about)),
            .separator(),
            item("Settings…", #selector(openSettings), ","),
            .separator(),
            NSMenuItem(title: "Quit Perch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(newTab), "t"),
            item("New Private Tab", #selector(newPrivateTab), "n", [.command, .shift]),
            item("Reopen Closed Tab", #selector(reopen), "t", [.command, .shift]),
            .separator(),
            item("Open Location…", #selector(openLocation), "l"),
            .separator(),
            item("Close Tab", #selector(closeTab), "w"),
            item("Close Panel", #selector(closePanel), "w", [.command, .shift]),
        ]))

        main.addItem(submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            shortcut(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z"), [.command, .shift]),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            shortcut(NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v"),
                     [.command, .option, .shift]),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            .separator(),
            item("Copy Link", #selector(copyLink), "c", [.command, .shift]),
            .separator(),
            item("Find…", #selector(find), "f"),
        ]))

        main.addItem(submenu("View", [
            item("Reload Page", #selector(reload), "r"),
            item("Show All Tabs", #selector(showTabs), "\\", [.command, .shift]),
            .separator(),
            item("Actual Size", #selector(zoomReset), "0"),
            item("Zoom In", #selector(zoomIn), "="),
            item("Zoom In", #selector(zoomIn), "+"),
            item("Zoom Out", #selector(zoomOut), "-"),
            .separator(),
            item("Request Desktop or Mobile Site", #selector(toggleLayout), "d", [.command, .option]),
            item("Keep Open", #selector(togglePin), "p", [.command, .option]),
            .separator(),
            item("Phone Size", #selector(sizePhone), "1", [.command, .control]),
            item("Tablet Size", #selector(sizeTablet), "2", [.command, .control]),
            item("Desktop Size", #selector(sizeDesktop), "3", [.command, .control]),
        ]))

        main.addItem(submenu("History", [
            item("Back", #selector(back), "["),
            item("Forward", #selector(forward), "]"),
            item("Start Page", #selector(home), "h", [.command, .shift]),
            .separator(),
            item("Add to Favorites", #selector(favorite), "d"),
        ]))

        var tabs: [NSMenuItem] = [
            item("Show Next Tab", #selector(nextTab), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(previousTab), "[", [.command, .shift]),
            item("Show Next Tab", #selector(nextTab), "\t", [.control]),
            item("Show Previous Tab", #selector(previousTab), "\t", [.control, .shift]),
            .separator(),
        ]
        for n in 1...9 {
            let tab = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(selectTab(_:)), "\(n)")
            tab.tag = n
            tabs.append(tab)
        }
        main.addItem(submenu("Window", tabs))
        return main
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        holder.submenu = menu
        return holder
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        return item
    }

    private func shortcut(_ item: NSMenuItem, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        item.keyEquivalentModifierMask = mods
        return item
    }

    // MARK: Actions

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "A browser that lives in your menu bar.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func newTab() { browser.newTab(); panel.show() }
    @objc func newPrivateTab() { browser.newTab(privately: true); panel.show() }
    @objc func reopen() { browser.reopen(); panel.show() }
    @objc func openLocation() { panel.show(); browser.overview = false; browser.focusField() }
    @objc func closeTab() { browser.closeActive() }
    @objc func closePanel() { panel.hide() }
    @objc func copyLink() { browser.copyLink() }
    @objc func find() { browser.openFind() }
    @objc func reload() { browser.reload() }
    @objc func showTabs() { browser.showOverview() }
    @objc func zoomReset() { browser.zoom(0) }
    @objc func zoomIn() { browser.zoom(1) }
    @objc func zoomOut() { browser.zoom(-1) }
    @objc func toggleLayout() { browser.toggleLayout() }
    @objc func togglePin() { panel.setPinned(!Prefs.shared.pinned) }
    @objc func sizePhone() { panel.apply(.phone) }
    @objc func sizeTablet() { panel.apply(.tablet) }
    @objc func sizeDesktop() { panel.apply(.desktop) }
    @objc func back() { browser.goBack() }
    @objc func forward() { browser.goForward() }
    @objc func home() { browser.goHome() }
    @objc func favorite() { browser.toggleFavorite() }
    @objc func nextTab() { browser.cycle(1) }
    @objc func previousTab() { browser.cycle(-1) }

    @objc func selectTab(_ sender: NSMenuItem) {
        if sender.tag == 9 { browser.selectLast() } else { browser.select(index: sender.tag - 1) }
        browser.overview = false
    }

    @objc func openSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Perch Settings"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

extension Commands: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = browser.active
        switch item.action {
        case #selector(reopen): return browser.canReopen
        case #selector(back): return tab?.canGoBack ?? false
        case #selector(forward): return tab?.canGoForward ?? false
        case #selector(copyLink), #selector(find), #selector(toggleLayout), #selector(favorite):
            if item.action == #selector(favorite) {
                item.title = History.shared.isFavorite(tab?.url) ? "Remove from Favorites" : "Add to Favorites"
            }
            return tab?.url != nil
        case #selector(togglePin):
            item.state = Prefs.shared.pinned ? .on : .off
            return true
        case #selector(selectTab(_:)):
            return item.tag == 9 ? !browser.tabs.isEmpty : browser.tabs.count >= item.tag
        default:
            return true
        }
    }
}
