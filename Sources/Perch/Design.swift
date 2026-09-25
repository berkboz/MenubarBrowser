import SwiftUI
import AppKit

// Perch borrows its manners from the Mac itself: system colours, system type,
// SF Symbols, and a pane of glass. Everything it draws should feel like it
// shipped with the menu bar it hangs from.

enum Metrics {
    /// The glass the whole browser sits in.
    static let panelRadius: CGFloat = 18
    /// The page, set into the glass like a card.
    static let pageRadius: CGFloat = 12
    static let pageInset: CGFloat = 6
    static let toolbar: CGFloat = 46
    static let field: CGFloat = 30
    static let grip: CGFloat = 16
    /// Gap between the bottom of the menu bar and the top of the panel.
    static let drop: CGFloat = 6
    static let minSize = NSSize(width: 340, height: 420)
    /// Below this width a page gets the phone layout, when the agent is automatic.
    static let mobileBreak: CGFloat = 560
}

enum Motion {
    static let glide = Animation.spring(response: 0.34, dampingFraction: 0.84)
    static let settle = Animation.spring(response: 0.28, dampingFraction: 0.9)
    static let quick = Animation.easeOut(duration: 0.14)
}

/// The sizes a panel snaps to from the menu. Dragging the grip lands anywhere
/// in between.
enum SizePreset: String, CaseIterable, Identifiable {
    case phone, tablet, desktop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .phone: return "Phone"
        case .tablet: return "Tablet"
        case .desktop: return "Desktop"
        }
    }
    var symbol: String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .desktop: return "macbook"
        }
    }
    var size: NSSize {
        switch self {
        case .phone: return NSSize(width: 400, height: 720)
        case .tablet: return NSSize(width: 640, height: 800)
        case .desktop: return NSSize(width: 980, height: 820)
        }
    }
}

enum Look: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    func apply() {
        let wanted = appearance
        DispatchQueue.main.async { NSApp.appearance = wanted }
    }
}

// MARK: - Small shared pieces

/// A toolbar button: a symbol, a soft capsule of wash on hover, nothing else.
struct GlyphButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 13
    var weight: Font.Weight = .medium
    var tint: Color = .primary
    let action: () -> Void

    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(enabled ? tint.opacity(0.85) : Color.secondary.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hover && enabled ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}

/// A keycap, for the hints that teach a shortcut.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }
}

/// A site's mark: its own icon on a white tile when it has one, otherwise
/// its initial on a colour picked from its name, so the same site always
/// wears the same colour.
struct SiteMark: View {
    let host: String
    var icon: NSImage?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(LinearGradient(colors: [hue.opacity(0.85), hue],
                                             startPoint: .top, endPoint: .bottom))
                    Text(initial)
                        .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return name.first.map { String($0).uppercased() } ?? "•"
    }

    private var hue: Color {
        var hash: UInt64 = 5381
        for byte in host.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.82)
    }
}

extension URL {
    /// The host a person would say out loud: no "www.", no port.
    var displayHost: String {
        guard let host = host(percentEncoded: false) else {
            return isFileURL ? lastPathComponent : absoluteString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
