import SwiftUI
import AppKit

/// What the address field is doing while someone types in it: the text, what
/// it might mean, and which of those is picked.
final class OmniModel: ObservableObject {
    @Published var text = "" { didSet { if editing && text != oldValue { refresh() } } }
    @Published private(set) var editing = false
    @Published private(set) var rows: [Suggestion] = []
    /// nil means "whatever was typed"; otherwise an index into rows.
    @Published var picked: Int?

    private var remote: [String] = []
    private var task: URLSessionDataTask?
    private var debounce: DispatchWorkItem?
    private var privately = false
    private var original = ""

    struct Suggestion: Identifiable, Equatable {
        enum Kind: Equatable { case topHit, visit, favorite, search, address }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
        let url: URL
        var host: String { url.displayHost }
        static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id }
    }

    func begin(with tab: Tab) {
        privately = tab.isPrivate
        if let url = tab.url {
            original = Prefs.shared.engine.query(in: url) ?? url.absoluteString
        } else {
            original = ""
        }
        text = original
        editing = true
        rows = []
        picked = nil
    }

    func end() {
        editing = false
        task?.cancel()
        debounce?.cancel()
        // A moment's grace, so a click on a suggestion still lands on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.editing else { return }
            self.rows = []
            self.picked = nil
        }
    }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        if let p = picked {
            let next = p + step
            picked = next < 0 ? nil : min(next, rows.count - 1)
        } else if step > 0 {
            picked = 0
        }
    }

    /// Where Return goes.
    var destination: URL? {
        if let p = picked, rows.indices.contains(p) { return rows[p].url }
        return Browser.resolve(text)
    }

    private func refresh() {
        remote = []
        rebuild()
        fetchRemote()
    }

    private func rebuild() {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q != original else { rows = []; picked = nil; return }
        var out: [Suggestion] = []
        var seen = Set<String>()

        let favs = History.shared.favorites.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q)
        }
        let visits = privately ? [] : History.shared.matches(q, limit: 4)

        // Safari's Top Hit: when the typing is plainly the start of a place
        // you've been, Return goes there.
        var hit: Suggestion?
        if q.count >= 2, let first = visits.first, let url = URL(string: first.url),
           Self.bare(first.url).hasPrefix(q.lowercased()) {
            hit = Suggestion(kind: .topHit, title: first.title.isEmpty ? url.displayHost : first.title,
                             detail: Self.bare(first.url), url: url)
        }
        if let hit {
            out.append(hit)
            seen.insert(hit.url.absoluteString)
        }

        let looksLikeAddress = !q.contains(" ") && q.contains(".")
        if looksLikeAddress, let url = Browser.resolve(q), url.scheme?.hasPrefix("http") == true,
           !seen.contains(url.absoluteString) {
            out.append(Suggestion(kind: .address, title: url.displayHost, detail: "Go to site", url: url))
            seen.insert(url.absoluteString)
        }

        // The query itself, then what the engine thinks it might become.
        let engine = Prefs.shared.engine
        var searches = [q] + remote.filter { $0.lowercased() != q.lowercased() }
        searches = Array(searches.prefix(hit == nil ? 5 : 4))
        let searchRows = searches.map {
            Suggestion(kind: .search, title: $0, detail: engine.title, url: engine.search($0))
        }

        var sites: [Suggestion] = []
        for f in favs.prefix(2) {
            guard let url = URL(string: f.url), seen.insert(f.url).inserted else { continue }
            sites.append(Suggestion(kind: .favorite, title: f.title, detail: Self.bare(f.url), url: url))
        }
        for v in visits {
            guard let url = URL(string: v.url), seen.insert(v.url).inserted else { continue }
            sites.append(Suggestion(kind: .visit, title: v.title.isEmpty ? url.displayHost : v.title,
                                    detail: Self.bare(v.url), url: url))
        }

        out += searchRows
        out += sites.prefix(4)
        rows = out
        picked = hit == nil ? nil : 0
    }

    private func fetchRemote() {
        debounce?.cancel()
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard Prefs.shared.suggestions, !privately, q.count >= 1, q != original else { return }
        let work = DispatchWorkItem { [weak self] in self?.request(q) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func request(_ q: String) {
        var c: URLComponents
        if Prefs.shared.engine == .google {
            c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            c.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: q)]
        } else {
            c = URLComponents(string: "https://duckduckgo.com/ac/")!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "type", value: "list")]
        }
        guard let url = c.url else { return }
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1, let list = json[1] as? [String] else { return }
            DispatchQueue.main.async {
                guard let self, self.editing, self.text.trimmingCharacters(in: .whitespaces) == q else { return }
                self.remote = Array(list.prefix(6))
                let keep = self.picked
                self.rebuild()
                if keep != nil { self.picked = keep.map { min($0, self.rows.count - 1) } }
            }
        }
        task?.resume()
    }

    static func bare(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.lowercased().hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - The field

struct Omnibox: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var omni: OmniModel
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(fill)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                              lineWidth: focused ? 1.5 : 0.5)

            if tab.loading && !focused {
                GeometryReader { g in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(8, g.size.width * tab.progress), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .animation(.easeOut(duration: 0.25), value: tab.progress)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 1)
                .transition(.opacity)
            }

            HStack(spacing: 6) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(leadingTint)
                    .frame(width: 14)

                ZStack {
                    TextField("Search or enter website", text: $omni.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .opacity(focused ? 1 : 0)
                        .allowsHitTesting(focused)
                        .onSubmit(commit)
                        .onKeyPress(.upArrow) { omni.move(-1); return .handled }
                        .onKeyPress(.downArrow) { omni.move(1); return .handled }
                        .onKeyPress(.escape) { cancel(); return .handled }

                    if !focused {
                        Text(label)
                            .font(.system(size: 13, weight: tab.url == nil ? .regular : .medium))
                            .foregroundStyle(tab.url == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                    }
                }

                trailing
            }
            .padding(.leading, 9)
            .padding(.trailing, 4)
        }
        .frame(height: Metrics.field)
        .contentShape(Rectangle())
        .onTapGesture { if !focused { startEditing() } }
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
        .onChange(of: focused) { _, now in
            if !now { omni.end() } else if !omni.editing { omni.begin(with: tab) }
        }
        .onChange(of: browser.focusRequest) { _, _ in startEditing() }
        .animation(Motion.quick, value: focused)
    }

    private var fill: Color {
        if tab.isPrivate { return Color.indigo.opacity(focused ? 0.22 : 0.16) }
        return Color.primary.opacity(focused ? 0.04 : (hover ? 0.085 : 0.06))
    }

    private var label: String {
        guard let url = tab.url ?? tab.pending else { return "Search or enter website" }
        if let q = Prefs.shared.engine.query(in: url) { return q }
        return url.displayHost
    }

    private var leadingSymbol: String {
        if focused || tab.url == nil { return "magnifyingglass" }
        if tab.isPrivate { return "hand.raised.fill" }
        if let url = tab.url, Prefs.shared.engine.query(in: url) != nil { return "magnifyingglass" }
        return tab.secure ? "lock.fill" : "exclamationmark.triangle.fill"
    }

    private var leadingTint: Color {
        if tab.isPrivate && !focused { return .indigo }
        if !focused, tab.url != nil, !tab.secure, Prefs.shared.engine.query(in: tab.url!) == nil { return .orange }
        return .secondary
    }

    @ViewBuilder private var trailing: some View {
        if focused {
            if !omni.text.isEmpty {
                Button { omni.text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        } else if tab.url != nil {
            Button { tab.loading ? tab.stop() : tab.reload() } label: {
                Image(systemName: tab.loading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover || tab.loading ? 1 : 0)
            .help(tab.loading ? "Stop" : "Reload")
        }
    }

    private func startEditing() {
        omni.begin(with: tab)
        focused = true
    }

    private func commit() {
        guard let url = omni.destination else { return }
        let newTab = NSEvent.modifierFlags.contains(.command)
        focused = false
        browser.open(url, in: newTab ? .newTab(focus: true) : .current)
        browser.focusPage()
    }

    private func cancel() {
        focused = false
        if tab.isBlank {
            browser.panel?.hide()
        } else {
            browser.focusPage()
        }
    }
}

// MARK: - The list under it

struct SuggestionList: View {
    @ObservedObject var browser: Browser
    @ObservedObject var omni: OmniModel
    @ObservedObject private var icons = Icons.shared

    var body: some View {
        // One snapshot of the rows: the list can change while SwiftUI is still
        // building the old one, and indexing the live array then goes out of range.
        let rows = omni.rows
        VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0, rows[index - 1].kind == .search, row.kind != .search {
                    Divider().padding(.horizontal, 10).padding(.vertical, 3)
                }
                SuggestionRow(row: row, picked: omni.picked == index, icon: icons.icon(for: row.url.host ?? ""))
                    .onTapGesture {
                        browser.open(row.url, in: NSEvent.modifierFlags.contains(.command) ? .newTab(focus: true) : .current)
                        browser.focusPage()
                    }
                    .onHover { h in if h { omni.picked = index } }
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct SuggestionRow: View {
    let row: OmniModel.Suggestion
    let picked: Bool
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 9) {
            Group {
                switch row.kind {
                case .search:
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(picked ? Color.white : Color.secondary)
                case .address:
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(picked ? Color.white : Color.secondary)
                default:
                    SiteMark(host: row.host, icon: icon, size: 16)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.system(size: 13, weight: row.kind == .topHit ? .semibold : .regular))
                    .lineLimit(1)
                if row.kind != .search {
                    Text(row.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(picked ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if row.kind == .topHit {
                Text("Top Hit")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(picked ? Color.white.opacity(0.85) : .secondary)
            } else if row.kind == .favorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(picked ? Color.white.opacity(0.85) : .yellow)
            }
        }
        .foregroundStyle(picked ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: row.kind == .search ? 28 : 38)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(picked ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }
}
