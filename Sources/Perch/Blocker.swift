import WebKit

/// Ads and trackers, stopped before they load, by WebKit's own content
/// blocker. The list is short on purpose: the ad networks and trackers that
/// show up on most pages, and none of the cosmetic rules that break sites.
final class Blocker {
    static let shared = Blocker()
    private(set) var list: WKContentRuleList?
    private var waiting: [(WKContentRuleList) -> Void] = []

    private static let hosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagservices.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com", "moatads.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com", "smartadserver.com",
        "adform.net", "bidswitch.net", "sharethrough.com", "yieldmo.com", "3lift.com", "teads.tv",
        "media.net", "zedo.com", "serving-sys.com", "hotjar.com", "mixpanel.com", "fullstory.com",
        "chartbeat.com", "newrelic.com", "nr-data.net", "adroll.com", "bluekai.com", "krxd.net",
        "exelator.com", "mathtag.com", "demdex.net", "everesttech.net", "rlcdn.com", "agkn.com",
        "facebook.net/tr", "connect.facebook.net/signals", "ads-twitter.com", "static.ads-twitter.com",
        "ads.linkedin.com", "snap.licdn.com", "analytics.tiktok.com", "bat.bing.com", "clarity.ms",
    ]

    private init() {}

    func prepare() {
        let rules = Self.hosts.map { host -> [String: Any] in
            let pattern = "^https?://([^/]*\\.)?" + NSRegularExpression.escapedPattern(for: host)
            return [
                "trigger": ["url-filter": pattern, "load-type": ["third-party"]],
                "action": ["type": "block"],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "perch.blocker.1",
                                                                encodedContentRuleList: json) { list, error in
            DispatchQueue.main.async {
                if let error { NSLog("Perch: blocker didn't compile: \(error)") }
                guard let list else { return }
                self.list = list
                self.waiting.forEach { $0(list) }
                self.waiting = []
            }
        }
    }

    /// Calls back with the list at once if it's ready, or once it is.
    func whenReady(_ body: @escaping (WKContentRuleList) -> Void) {
        if let list { body(list) } else { waiting.append(body) }
    }
}
