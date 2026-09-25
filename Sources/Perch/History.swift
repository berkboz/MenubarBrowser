import AppKit

/// Where Perch keeps what it remembers: ~/Library/Application Support/Perch.
enum Storage {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Perch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let icons: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Perch/Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

struct Visit: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var last: Date
    var count: Int
    var id: String { url }
}

struct Favorite: Codable, Identifiable, Hashable {
    var url: String
    var title: String
    var id: String { url }
}

/// Pages visited and pages kept. Private tabs never write here.
final class History: ObservableObject {
    static let shared = History()

    @Published private(set) var visits: [String: Visit] = [:]
    @Published private(set) var favorites: [Favorite] = []
    private var pending: DispatchWorkItem?
    private static let cap = 4000

    private init() {
        visits = Storage.load([String: Visit].self, from: "history.json") ?? [:]
        favorites = Storage.load([Favorite].self, from: "favorites.json") ?? Favorite.starters
    }

    func record(_ url: URL, title: String) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        var visit = visits[key] ?? Visit(url: key, title: title, last: Date(), count: 0)
        visit.count += 1
        visit.last = Date()
        if !title.isEmpty { visit.title = title }
        visits[key] = visit
        if visits.count > Self.cap {
            let oldest = visits.values.sorted { $0.last < $1.last }.prefix(visits.count - Self.cap)
            for v in oldest { visits[v.url] = nil }
        }
        scheduleSave()
    }

    /// A title arrives after the visit has been recorded, often by a second or two.
    func retitle(_ url: URL, title: String) {
        let key = url.absoluteString
        guard !title.isEmpty, visits[key] != nil, visits[key]?.title != title else { return }
        visits[key]?.title = title
        scheduleSave()
    }

    func clear() {
        visits = [:]
        Storage.save(visits, to: "history.json")
    }

    /// The addresses and titles that match what's been typed so far, best first.
    /// An address that starts with the text wins over one that only contains it,
    /// and pages visited often and lately win over the rest.
    func matches(_ text: String, limit: Int = 5) -> [Visit] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let now = Date()
        return visits.values.compactMap { v -> (Visit, Double)? in
            let bare = Self.bare(v.url)
            let title = v.title.lowercased()
            var score: Double
            if bare.hasPrefix(q) { score = 100 }
            else if bare.contains(q) { score = 40 }
            else if title.contains(q) { score = 30 }
            else { return nil }
            let days = now.timeIntervalSince(v.last) / 86_400
            score += min(Double(v.count), 50) * 2 - min(days, 60) * 0.5
            // A short address beats a deep link to the same place.
            score -= Double(bare.count) * 0.05
            return (v, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map { $0.0 }
    }

    /// The sites people come back to, one entry per site.
    func frequent(limit: Int = 8) -> [Visit] {
        var seen = Set<String>()
        let kept = Set(favorites.compactMap { URL(string: $0.url)?.displayHost })
        return visits.values
            .sorted { $0.count == $1.count ? $0.last > $1.last : $0.count > $1.count }
            .filter { v in
                guard let host = URL(string: v.url)?.displayHost, !kept.contains(host) else { return false }
                return seen.insert(host).inserted
            }
            .prefix(limit)
            .map { v in
                // The site, not whatever page on it happened to be counted.
                guard let url = URL(string: v.url), let scheme = url.scheme, let host = url.host else { return v }
                var site = v
                site.url = "\(scheme)://\(host)/"
                site.title = url.displayHost
                return site
            }
    }

    // MARK: Favorites

    func isFavorite(_ url: URL?) -> Bool {
        guard let url else { return false }
        return favorites.contains { $0.url == url.absoluteString }
    }

    func toggleFavorite(_ url: URL, title: String) {
        if let i = favorites.firstIndex(where: { $0.url == url.absoluteString }) {
            favorites.remove(at: i)
        } else {
            favorites.append(Favorite(url: url.absoluteString, title: title.isEmpty ? url.displayHost : title))
        }
        Storage.save(favorites, to: "favorites.json")
    }

    func removeFavorite(_ fav: Favorite) {
        favorites.removeAll { $0 == fav }
        Storage.save(favorites, to: "favorites.json")
    }

    func moveFavorite(_ fav: Favorite, before target: Favorite) {
        guard let from = favorites.firstIndex(of: fav), let to = favorites.firstIndex(of: target), from != to else { return }
        let item = favorites.remove(at: from)
        favorites.insert(item, at: to)
        Storage.save(favorites, to: "favorites.json")
    }

    // MARK: Saving

    private func scheduleSave() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Storage.save(self.visits, to: "history.json")
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func flush() {
        pending?.perform()
        pending = nil
    }

    private static func bare(_ url: String) -> String {
        var s = url.lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }
}

extension Favorite {
    static let starters: [Favorite] = [
        Favorite(url: "https://www.apple.com/", title: "Apple"),
        Favorite(url: "https://news.ycombinator.com/", title: "Hacker News"),
        Favorite(url: "https://www.wikipedia.org/", title: "Wikipedia"),
        Favorite(url: "https://github.com/", title: "GitHub"),
    ]
}

// MARK: - Icons

/// Site icons, by host: in memory while Perch runs, on disk between runs.
/// A page's apple-touch-icon is preferred, being large enough to look good on
/// the start page; the plain favicon is the fallback.
final class Icons: ObservableObject {
    static let shared = Icons()
    @Published private(set) var byHost: [String: NSImage] = [:]
    private var inFlight = Set<String>()
    private var missing = Set<String>()

    func icon(for host: String) -> NSImage? {
        if let image = byHost[host] { return image }
        guard !missing.contains(host) else { return nil }
        let file = Storage.icons.appendingPathComponent(Self.fileName(host))
        if let image = NSImage(contentsOf: file) {
            DispatchQueue.main.async { self.byHost[host] = image }
            return image
        }
        missing.insert(host)
        fetch(host: host, from: URL(string: "https://\(host)/apple-touch-icon.png"),
              fallback: URL(string: "https://\(host)/favicon.ico"))
        return nil
    }

    func fetch(host: String, from url: URL?, fallback: URL? = nil) {
        guard let url, !inFlight.contains(host) else { return }
        inFlight.insert(host)
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue(Agent.mac, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let image = ok ? data.flatMap(NSImage.init(data:)) : nil
            DispatchQueue.main.async {
                self.inFlight.remove(host)
                guard let image, image.size.width >= 8 else {
                    if let fallback { self.fetch(host: host, from: fallback) }
                    return
                }
                self.missing.remove(host)
                self.byHost[host] = image
                if let data {
                    try? data.write(to: Storage.icons.appendingPathComponent(Self.fileName(host)), options: .atomic)
                }
            }
        }.resume()
    }

    /// The best icon a loaded page declares, or its favicon.ico.
    static let finder = """
    (() => {
      const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"], link[rel="shortcut icon"]')];
      const touch = links.find(l => l.rel.includes('apple-touch-icon'));
      const sized = links.filter(l => l.sizes && l.sizes.length).sort((a, b) => parseInt(b.sizes[0]) - parseInt(a.sizes[0]))[0];
      const pick = touch || sized || links[links.length - 1];
      return pick ? pick.href : new URL('/favicon.ico', location.href).href;
    })()
    """

    private static func fileName(_ host: String) -> String {
        host.replacingOccurrences(of: "/", with: "_") + ".img"
    }
}
