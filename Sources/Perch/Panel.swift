import AppKit
import SwiftUI

/// The pane of glass that drops from the menu bar. Borderless, rounded, with
/// the vibrancy of a popover and none of its arrow.
final class GlassPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    let panel: GlassPanel
    let browser: Browser
    private let prefs = Prefs.shared
    weak var anchor: NSStatusBarButton?

    private var generation = 0
    private var shownOnce = false
    private var resizeStart: (mouse: NSPoint, frame: NSRect)?
    private var observers: [NSObjectProtocol] = []

    var isShown: Bool { panel.isVisible && panel.alphaValue > 0 }

    init(browser: Browser) {
        self.browser = browser
        panel = GlassPanel(contentRect: NSRect(origin: .zero, size: Prefs.shared.size),
                           styleMask: [.borderless, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        super.init()
        browser.panel = self

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = prefs.pinned
        panel.isMovableByWindowBackground = false
        panel.minSize = Metrics.minSize
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.escape() }

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.mask(radius: Metrics.panelRadius)

        let host = NSHostingView(rootView: RootView(browser: browser, stage: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        // The panel's size is Perch's to set, not SwiftUI's: left to itself
        // the hosting view would shrink the window to its content's ideal size.
        host.sizingOptions = []
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lostFocus()
        })
    }

    // MARK: Showing and hiding

    func toggle() {
        isShown && NSApp.isActive ? hide() : show()
    }

    func show() {
        generation += 1
        // A panel that was dragged somewhere comes back where it was left.
        let target = prefs.pinned && shownOnce ? panel.frame : anchoredFrame(for: prefs.size)
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if wasVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // A short fall from just under the menu bar, like a menu opening.
            panel.setFrame(target.offsetBy(dx: 0, dy: 10), display: false)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        shownOnce = true
        anchor?.highlight(true)
        browser.panelResized(width: target.width)
        browser.wakeActive()
        browser.panelDidShow()
    }

    /// `giveBack` hands focus back to whatever app was in front before Perch,
    /// which is what a person expects after pressing Escape or the hot key.
    func hide(giveBack: Bool = true) {
        guard panel.isVisible else { return }
        generation += 1
        let mine = generation
        anchor?.highlight(false)
        browser.save()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == mine else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            if giveBack && NSApp.isActive && !self.otherWindowsOpen { NSApp.hide(nil) }
        })
    }

    private func escape() {
        if browser.finding { browser.finding = false; browser.focusPage(); return }
        if browser.overview { withAnimation(Motion.glide) { browser.overview = false }; return }
        hide()
    }

    private func lostFocus() {
        guard !prefs.pinned, browser.holdOpen == 0, panel.attachedSheet == nil else { return }
        hide(giveBack: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus went to another of Perch's own windows (Settings, a file
        // picker): stay. Focus left Perch entirely: didResignActive handles it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !NSApp.isActive { self.lostFocus() }
        }
    }

    private var otherWindowsOpen: Bool {
        NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) && $0.level == .normal }
    }

    // MARK: Place and size

    /// Centred under the menu bar icon, kept on the screen.
    func anchoredFrame(for size: NSSize) -> NSRect {
        let screen = anchor?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = min(max(size.width, Metrics.minSize.width), visible.width - 16)
        let top: CGFloat
        let midX: CGFloat
        if let button = anchor, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            top = min(rect.minY, visible.maxY) - Metrics.drop
            midX = rect.midX
        } else {
            top = visible.maxY - Metrics.drop
            midX = visible.midX
        }
        let height = min(max(size.height, Metrics.minSize.height), top - visible.minY - 8)
        var x = midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    func apply(_ preset: SizePreset) {
        prefs.size = preset.size
        let target = prefs.pinned ? NSRect(origin: NSPoint(x: panel.frame.minX, y: panel.frame.maxY - preset.size.height),
                                            size: preset.size)
                                   : anchoredFrame(for: preset.size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(target, display: true)
        }
        browser.panelResized(width: target.width)
    }

    func setPinned(_ pinned: Bool) {
        prefs.pinned = pinned
        panel.isMovable = pinned
        if !pinned && panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                panel.animator().setFrame(anchoredFrame(for: panel.frame.size), display: true)
            }
        }
    }

    /// Lifted off the menu bar by dragging the toolbar: it stays open and
    /// stays put until double-clicked back.
    func detach() {
        guard !prefs.pinned else { return }
        prefs.pinned = true
        panel.isMovable = true
        browser.flash(symbol: "pin.fill", text: "Kept open · double-click the toolbar to dock")
    }

    func cyclePreset() {
        let now = panel.frame.size
        let all = SizePreset.allCases
        // The next preset larger than the panel is now, wrapping to the smallest.
        let next = all.first { $0.size.width > now.width + 1 } ?? all[0]
        apply(next)
    }

    /// The grip at the bottom: drag down for taller, sideways for wider. When
    /// the panel hangs from the menu bar it grows both ways at once so it
    /// stays centred under the icon.
    func resize(dragging: Bool) {
        guard dragging else {
            resizeStart = nil
            prefs.size = panel.frame.size
            panel.invalidateShadow()
            return
        }
        let mouse = NSEvent.mouseLocation
        if resizeStart == nil { resizeStart = (mouse, panel.frame) }
        guard let start = resizeStart else { return }
        let dx = mouse.x - start.mouse.x
        let dy = mouse.y - start.mouse.y
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let symmetric = !prefs.pinned
        var width = start.frame.width + (symmetric ? dx * 2 : dx)
        var height = start.frame.height - dy
        width = min(max(width, Metrics.minSize.width), screen.width - 16)
        height = min(max(height, Metrics.minSize.height), start.frame.maxY - screen.minY - 8)
        var x = symmetric ? start.frame.midX - width / 2 : start.frame.minX
        x = min(max(x, screen.minX + 8), screen.maxX - width - 8)
        panel.setFrame(NSRect(x: x, y: start.frame.maxY - height, width: width, height: height), display: true)
        browser.panelResized(width: width)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        prefs.size = panel.frame.size
        browser.panelResized(width: panel.frame.width)
    }

    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
