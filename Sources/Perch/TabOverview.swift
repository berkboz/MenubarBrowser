import SwiftUI
import AppKit

/// Every tab at once, as cards: Safari on iPhone's grid, shrunk to fit under
/// the menu bar.
struct TabOverview: View {
    @ObservedObject var browser: Browser

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(browser.tabs) { tab in
                            TabCard(tab: tab, active: tab === browser.active) {
                                browser.select(tab)
                                withAnimation(Motion.glide) { browser.overview = false }
                            } close: {
                                withAnimation(Motion.settle) { browser.close(tab) }
                            }
                            .id(tab.id)
                            .contextMenu {
                                Button("Close Tab") { withAnimation(Motion.settle) { browser.close(tab) } }
                                Button("Close Other Tabs") { withAnimation(Motion.settle) { browser.closeOthers(than: tab) } }
                                if let url = tab.url {
                                    Divider()
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                }
                            }
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.never)
                .onAppear {
                    if let id = browser.active?.id { proxy.scrollTo(id, anchor: .center) }
                }
            }

            HStack {
                Button {
                    browser.newTab(privately: true)
                } label: {
                    Label("Private", systemImage: "hand.raised")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    browser.newTab()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("New Tab")

                Spacer()

                Button("Done") {
                    withAnimation(Motion.glide) { browser.overview = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: Tab
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    @ObservedObject private var icons = Icons.shared
    @State private var hover = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topLeading) {
                thumbnail
                    .frame(height: 176)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.1),
                                          lineWidth: active ? 2.5 : 0.5)
                    )
                    .shadow(color: .black.opacity(hover ? 0.2 : 0.1), radius: hover ? 10 : 4, y: hover ? 5 : 2)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(7)
                .opacity(hover ? 1 : 0)
                .help("Close Tab")
            }
            .scaleEffect(hover ? 1.02 : 1)

            HStack(spacing: 5) {
                if tab.isPrivate {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.indigo)
                } else if !tab.host.isEmpty {
                    SiteMark(host: tab.host, icon: icons.icon(for: (tab.url ?? tab.pending)?.host ?? ""), size: 13)
                }
                Text(tab.displayTitle)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(Motion.settle) { hover = h } }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = tab.snapshot, tab.url != nil {
            GeometryReader { g in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    .clipped()
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ZStack {
                Rectangle().fill(tab.isPrivate ? Color.indigo.opacity(0.12) : Color.primary.opacity(0.05))
                if tab.host.isEmpty {
                    Image(systemName: tab.isPrivate ? "hand.raised" : "square.grid.2x2")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                } else {
                    SiteMark(host: tab.host, icon: icons.icon(for: (tab.url ?? tab.pending)?.host ?? ""), size: 40)
                }
            }
        }
    }
}
