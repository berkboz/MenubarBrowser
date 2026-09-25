import AppKit
import Carbon.HIToolbox

/// Everything a person can choose, kept in UserDefaults and published so the
/// interface follows along as it changes.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let store = UserDefaults.standard

    @Published var engine: Engine { didSet { store.set(engine.rawValue, forKey: "engine") } }
    @Published var agent: Agent { didSet { store.set(agent.rawValue, forKey: "agent") } }
    @Published var suggestions: Bool { didSet { store.set(suggestions, forKey: "suggestions") } }
    @Published var blockAds: Bool { didSet { store.set(blockAds, forKey: "blockAds") } }
    @Published var look: Look { didSet { store.set(look.rawValue, forKey: "look"); look.apply() } }
    @Published var hotKey: KeyCombo? {
        didSet {
            if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
                store.set(data, forKey: "hotKey")
            } else {
                store.set(Data(), forKey: "hotKey")
            }
        }
    }
    /// Keep the panel up when the pointer goes elsewhere. A pinned panel can
    /// also be dragged away from the menu bar and left anywhere.
    @Published var pinned: Bool { didSet { store.set(pinned, forKey: "pinned") } }
    @Published var size: NSSize {
        didSet {
            store.set(size.width, forKey: "width")
            store.set(size.height, forKey: "height")
        }
    }
    var welcomed: Bool {
        get { store.bool(forKey: "welcomed") }
        set { store.set(newValue, forKey: "welcomed") }
    }

    private init() {
        engine = Engine(rawValue: store.string(forKey: "engine") ?? "") ?? .google
        agent = Agent(rawValue: store.string(forKey: "agent") ?? "") ?? .automatic
        suggestions = store.object(forKey: "suggestions") as? Bool ?? true
        blockAds = store.object(forKey: "blockAds") as? Bool ?? true
        look = Look(rawValue: store.string(forKey: "look") ?? "") ?? .system
        pinned = store.bool(forKey: "pinned")
        let w = store.double(forKey: "width"), h = store.double(forKey: "height")
        size = w > 0 && h > 0 ? NSSize(width: w, height: h) : SizePreset.phone.size
        if let data = store.data(forKey: "hotKey") {
            hotKey = data.isEmpty ? nil : (try? JSONDecoder().decode(KeyCombo.self, from: data))
        } else {
            hotKey = .standard
        }
    }
}

// MARK: - Search engines

enum Engine: String, CaseIterable, Identifiable {
    case google, duckduckgo, kagi, bing, brave, ecosia, perplexity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .kagi: return "Kagi"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .ecosia: return "Ecosia"
        case .perplexity: return "Perplexity"
        }
    }

    func search(_ query: String) -> URL {
        var c: URLComponents
        switch self {
        case .google: c = URLComponents(string: "https://www.google.com/search")!
        case .duckduckgo: c = URLComponents(string: "https://duckduckgo.com/")!
        case .kagi: c = URLComponents(string: "https://kagi.com/search")!
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!
        case .brave: c = URLComponents(string: "https://search.brave.com/search")!
        case .ecosia: c = URLComponents(string: "https://www.ecosia.org/search")!
        case .perplexity: c = URLComponents(string: "https://www.perplexity.ai/search")!
        }
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url!
    }

    /// Whether a page is this engine's own results page, so the field can show
    /// the query rather than a long address.
    func query(in url: URL) -> String? {
        guard let host = url.host, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let matches: Bool
        switch self {
        case .google: matches = host.contains("google.") && url.path == "/search"
        case .duckduckgo: matches = host.hasSuffix("duckduckgo.com")
        case .kagi: matches = host.hasSuffix("kagi.com") && url.path == "/search"
        case .bing: matches = host.hasSuffix("bing.com") && url.path == "/search"
        case .brave: matches = host == "search.brave.com"
        case .ecosia: matches = host.hasSuffix("ecosia.org") && url.path == "/search"
        case .perplexity: matches = false
        }
        guard matches else { return nil }
        return c.queryItems?.first(where: { $0.name == "q" })?.value
    }
}

// MARK: - User agent

/// Which layout pages are asked for. A menu bar browser is usually narrow, and
/// most sites look far better in their phone layout at that width.
enum Agent: String, CaseIterable, Identifiable {
    case automatic, mobile, desktop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .mobile: return "Mobile"
        case .desktop: return "Desktop"
        }
    }

    static let iPhone =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    static let mac =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
}

// MARK: - Hot key

/// A key and its modifiers, in the form Carbon's hot key API wants them, with
/// the label to show a person.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    /// ⌥Space: out of the way of Spotlight (⌘Space) and input sources (⌃Space).
    static let standard = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")

    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// Keycaps, one per modifier and one for the key.
    var caps: [String] {
        var caps: [String] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { caps.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { caps.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { caps.append("⌘") }
        caps.append(key)
        return caps
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// From a key press; nil when there is no modifier, since a bare key would
    /// be stolen from every app on the Mac.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        guard m != 0, m != UInt32(shiftKey) else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = m
        key = KeyCombo.name(for: Int(event.keyCode), fallback: event.charactersIgnoringModifiers)
    }

    private static func name(for code: Int, fallback: String?) -> String {
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return (fallback ?? "?").uppercased()
        }
    }
}
