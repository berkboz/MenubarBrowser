import SwiftUI
import AppKit
import WebKit

/// Everything inside the glass: a toolbar, the page set into it like a card,
/// and a grip to pull it bigger.
struct RootView: View {
    @ObservedObject var browser: Browser
    let stage: PanelController
    @StateObject private var omni = OmniModel()

    var body: some View {
        VStack(spacing: 0) {
            if let tab = browser.active {
                Toolbar(browser: browser, tab: tab, stage: stage, omni: omni)
            }

            if browser.finding {
                FindBar(browser: browser)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                if browser.overview {
                    TabOverview(browser: browser)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)),
                                                removal: .opacity))
                } else if let tab = browser.active {
                    PageArea(browser: browser, tab: tab)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Grip(stage: stage)
        }
        .overlay(alignment: .top) {
            if omni.editing && !omni.rows.isEmpty {
                SuggestionList(browser: browser, omni: omni)
                    .padding(.horizontal, 10)
                    .padding(.top, Metrics.toolbar - 4)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = browser.toast {
                ToastView(toast: toast) { withAnimation(Motion.settle) { browser.toast = nil } }
                    .padding(.bottom, Metrics.grip + 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .animation(Motion.settle, value: omni.rows.isEmpty)
        .animation(Motion.settle, value: browser.finding)
        .animation(Motion.glide, value: browser.overview)
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let stage: PanelController
    @ObservedObject var omni: OmniModel

    var body: some View {
        HStack(spacing: 2) {
            GlyphButton(symbol: "chevron.left", help: "Back") { browser.goBack() }
                .disabled(!tab.canGoBack)
            GlyphButton(symbol: "chevron.right", help: "Forward") { browser.goForward() }
                .disabled(!tab.canGoForward)

            Omnibox(browser: browser, tab: tab, omni: omni)
                .padding(.horizontal, 6)

            TabsButton(count: browser.tabs.count, on: browser.overview, privately: tab.isPrivate) {
                browser.showOverview()
            }
            MoreButton()
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.toolbar)
        .background(DragArea(stage: stage))
    }
}

/// The count of open tabs in a little square, like Safari on iPhone. Opens
/// the grid of all of them.
private struct TabsButton: View {
    let count: Int
    let on: Bool
    let privately: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.8), lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(on ? Color.primary.opacity(0.85) : .clear)
                    )
                    .frame(width: 17, height: 17)
                Text(count > 99 ? "∞" : "\(count)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .primary.opacity(0.85))
                    .contentTransition(.numericText())
            }
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show All Tabs")
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
        .animation(Motion.settle, value: count)
    }
}

/// "⋯", which opens a real menu — AppKit's, so it can show the shortcuts.
private struct MoreButton: View {
    @State private var frame: CGRect = .zero

    var body: some View {
        GlyphButton(symbol: "ellipsis.circle", help: "More") {
            Commands.current?.popUpMore(below: frame)
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            }
        )
    }
}

/// The empty stretches of the toolbar. Dragging there lifts the panel off the
/// menu bar and leaves it wherever it's dropped, kept open; a double-click
/// puts it back.
struct DragArea: NSViewRepresentable {
    let stage: PanelController

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.stage = stage
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.stage = stage
    }

    final class DragView: NSView {
        weak var stage: PanelController?
        private var start: (mouse: NSPoint, origin: NSPoint)?
        private var moved = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                if Prefs.shared.pinned { stage?.setPinned(false) }
                return
            }
            guard let window else { return }
            start = (NSEvent.mouseLocation, window.frame.origin)
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - start.mouse.x, dy = now.y - start.mouse.y
            if !moved {
                guard hypot(dx, dy) > 4 else { return }
                moved = true
                stage?.detach()
            }
            window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
        }
    }
}

// MARK: - The page

private struct PageArea: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        ZStack {
            if tab.isBlank {
                StartPage(browser: browser, tab: tab)
                    .transition(.opacity)
            } else {
                WebArea(tab: tab)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    )
                    .overlay {
                        if let failure = tab.failure {
                            FailureView(failure: failure) { tab.reload() }
                                .clipShape(RoundedRectangle(cornerRadius: Metrics.pageRadius, style: .continuous))
                                .transition(.opacity)
                        }
                    }
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            }
        }
        .padding(.horizontal, Metrics.pageInset)
        .animation(Motion.quick, value: tab.failure)
    }
}

/// The tab's own web view, set into a rounded card. The view is moved from
/// card to card rather than rebuilt, so a page never reloads because its tab
/// was switched away from.
private struct WebArea: NSViewRepresentable {
    @ObservedObject var tab: Tab

    func makeNSView(context: Context) -> Card {
        Card()
    }

    func updateNSView(_ card: Card, context: Context) {
        card.show(tab.webView)
    }

    final class Card: NSView {
        private weak var current: WKWebView?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = Metrics.pageRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ web: WKWebView) {
            guard current !== web || web.superview !== self else { return }
            current?.removeFromSuperview()
            web.removeFromSuperview()
            web.frame = bounds
            web.autoresizingMask = [.width, .height]
            addSubview(web)
            current = web
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            }
        }
    }
}

private struct FailureView: View {
    let failure: Tab.Failure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: failure.offline ? "wifi.slash" : "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(failure.offline ? "You're not connected to the internet" : "Perch can't open this page")
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(failure.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if let host = failure.url?.displayHost, !host.isEmpty {
                Text(host)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Find

private struct FindBar: View {
    @ObservedObject var browser: Browser
    @State private var text = ""
    @State private var missing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Find on page", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { go(backwards: NSEvent.modifierFlags.contains(.shift)) }
                    .onKeyPress(.escape) { close(); return .handled }
                if missing && !text.isEmpty {
                    Text("Not found")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            GlyphButton(symbol: "chevron.up", help: "Previous", size: 11) { go(backwards: true) }
                .disabled(text.isEmpty)
            GlyphButton(symbol: "chevron.down", help: "Next", size: 11) { go(backwards: false) }
                .disabled(text.isEmpty)
            Button("Done", action: close)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: text) { _, _ in go(backwards: false) }
    }

    private func go(backwards: Bool) {
        browser.find(text, backwards: backwards) { found in missing = !found }
    }

    private func close() {
        browser.finding = false
        browser.focusPage()
    }
}

// MARK: - Grip

/// A small bar at the bottom edge: drag to size the panel, double-click to
/// step through Phone, Tablet and Desktop.
private struct Grip: View {
    let stage: PanelController
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(hover || dragging ? 0.4 : 0.18))
            .frame(width: hover || dragging ? 44 : 34, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.grip)
            .contentShape(Rectangle())
            .onHover { h in
                withAnimation(Motion.quick) { hover = h }
                if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        dragging = true
                        stage.resize(dragging: true)
                    }
                    .onEnded { _ in
                        dragging = false
                        stage.resize(dragging: false)
                    }
            )
            .onTapGesture(count: 2) { stage.cyclePreset() }
            .contextMenu {
                ForEach(SizePreset.allCases) { preset in
                    Button { stage.apply(preset) } label: { Label(preset.title, systemImage: preset.symbol) }
                }
            }
            .help("Drag to resize · Double-click to change size")
    }
}

// MARK: - Toast

private struct ToastView: View {
    let toast: Browser.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(toast.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) { action(); dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 320)
    }
}
