import SwiftUI
import AppKit

/// What a new tab shows: the day, your favourites, the places you go most,
/// laid straight onto the glass.
struct StartPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var history = History.shared
    @ObservedObject private var icons = Icons.shared
    @ObservedObject private var prefs = Prefs.shared

    private let columns = [GridItem(.adaptive(minimum: 74, maximum: 96), spacing: 8, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if tab.isPrivate {
                    PrivateNote()
                }

                if !history.favorites.isEmpty {
                    section("Favorites") {
                        ForEach(history.favorites) { fav in
                            Tile(title: fav.title, url: URL(string: fav.url), icons: icons) {
                                open(fav.url)
                            }
                            .contextMenu {
                                Button("Open in New Tab") { openNew(fav.url) }
                                Button("Copy Link") { copy(fav.url) }
                                Divider()
                                Button("Remove from Favorites") {
                                    withAnimation(Motion.settle) { history.removeFavorite(fav) }
                                }
                            }
                            .draggable(fav.url)
                            .dropDestination(for: String.self) { items, _ in
                                guard let from = items.first,
                                      let moving = history.favorites.first(where: { $0.url == from }) else { return false }
                                withAnimation(Motion.settle) { history.moveFavorite(moving, before: fav) }
                                return true
                            }
                        }
                    }
                }

                let frequent = tab.isPrivate ? [] : history.frequent(limit: 8)
                if !frequent.isEmpty {
                    section("Frequently Visited") {
                        ForEach(frequent) { visit in
                            Tile(title: visit.title, url: URL(string: visit.url), icons: icons) {
                                open(visit.url)
                            }
                            .contextMenu {
                                Button("Open in New Tab") { openNew(visit.url) }
                                Button("Add to Favorites") {
                                    if let url = URL(string: visit.url) {
                                        withAnimation(Motion.settle) { history.toggleFavorite(url, title: visit.title) }
                                    }
                                }
                            }
                        }
                    }
                }

                hints
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 3) {
                Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text(tab.isPrivate ? "Private Browsing" : Self.greeting(for: context.date))
                    .font(.system(size: 26, weight: .bold))
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                content()
            }
        }
    }

    @ViewBuilder private var hints: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let combo = prefs.hotKey {
                hint(caps: combo.caps, text: "opens Perch from anywhere")
            }
            hint(caps: ["⌘", "T"], text: "new tab  ·  ⌘-click a link to open it behind")
            hint(caps: ["⌥", "⌘", "D"], text: "switches between mobile and desktop sites")
            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 11))
                Text("Drag the toolbar to keep Perch open anywhere")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
    }

    private func hint(caps: [String], text: String) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in Keycap(text: cap) }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        browser.open(url, in: NSEvent.modifierFlags.contains(.command) ? .newTab(focus: false) : .current)
        browser.focusPage()
    }

    private func openNew(_ string: String) {
        guard let url = URL(string: string) else { return }
        browser.open(url, in: .newTab(focus: false))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }
}

/// One site on the start page: its icon on a white tile, or its initial on
/// a colour of its own, with its name under it.
private struct Tile: View {
    let title: String
    let url: URL?
    @ObservedObject var icons: Icons
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let host = url?.host ?? ""
        let icon = icons.icon(for: host)
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    if let icon {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: icon.size.width >= 64 ? 56 : 30,
                                   height: icon.size.width >= 64 ? 56 : 30)
                            .clipShape(RoundedRectangle(cornerRadius: icon.size.width >= 64 ? 14 : 4, style: .continuous))
                    } else {
                        SiteMark(host: url?.displayHost ?? title, icon: nil, size: 56)
                    }
                }
                .frame(width: 56, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(hover ? 0.18 : 0.08), radius: hover ? 8 : 3, y: hover ? 4 : 1)
                .scaleEffect(hover ? 1.05 : 1)

                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 76)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url?.absoluteString ?? title)
        .onHover { h in withAnimation(Motion.settle) { hover = h } }
    }
}

private struct PrivateNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 18))
                .foregroundStyle(.indigo)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.indigo.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) {
                Text("This tab is private")
                    .font(.system(size: 13, weight: .semibold))
                Text("Perch won't remember the pages you visit or what you search for, and doesn't bring this tab back next time. Its cookies are forgotten when the last private tab closes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.indigo.opacity(0.07))
        )
    }
}
