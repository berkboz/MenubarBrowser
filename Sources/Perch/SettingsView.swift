import SwiftUI
import AppKit
import WebKit

struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var openAtLogin = LoginItem.enabled
    @State private var confirmHistory = false
    @State private var confirmData = false
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Perch")
                            .font(.system(size: 17, weight: .semibold))
                        Text("A browser that lives in your menu bar")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("General") {
                LabeledContent("Keyboard shortcut") {
                    HotKeyRecorder(combo: $prefs.hotKey)
                }
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
                Toggle("Keep open when clicking elsewhere", isOn: Binding(
                    get: { prefs.pinned },
                    set: { Commands.current?.panel.setPinned($0) }
                ))
                Picker("Appearance", selection: $prefs.look) {
                    ForEach(Look.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: Binding(
                    get: { SizePreset.allCases.first { $0.size == prefs.size } },
                    set: { if let p = $0 { Commands.current?.panel.apply(p) } }
                )) {
                    ForEach(SizePreset.allCases) { Label($0.title, systemImage: $0.symbol).tag(Optional($0)) }
                    if !SizePreset.allCases.contains(where: { $0.size == prefs.size }) {
                        Text("Custom").tag(SizePreset?.none)
                    }
                }
            }

            Section {
                Picker("Search engine", selection: $prefs.engine) {
                    ForEach(Engine.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show search suggestions", isOn: $prefs.suggestions)
                Picker("Website layout", selection: $prefs.agent) {
                    ForEach(Agent.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Block ads and trackers", isOn: $prefs.blockAds)
            } header: {
                Text("Browsing")
            } footer: {
                Text("Automatic asks for a site's mobile layout while Perch is narrower than \(Int(Metrics.mobileBreak)) points, which suits most sites at menu bar size.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                LabeledContent("History") {
                    Button("Clear History…") { confirmHistory = true }
                }
                LabeledContent("Cookies and website data") {
                    Button("Clear…") { confirmData = true }
                }
            }

            Section {
                LabeledContent("Default browser") {
                    Button("Make Perch the Default") { makeDefault() }
                }
            } footer: {
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
        .confirmationDialog("Clear all history?", isPresented: $confirmHistory) {
            Button("Clear History", role: .destructive) {
                History.shared.clear()
                note = "History cleared."
            }
        } message: {
            Text("Every page Perch remembers visiting will be forgotten. Favorites are kept.")
        }
        .confirmationDialog("Clear cookies and website data?", isPresented: $confirmData) {
            Button("Clear", role: .destructive) {
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    note = "Cookies and website data cleared. You'll be signed out of websites."
                }
            }
        } message: {
            Text("You'll be signed out of every website you use in Perch.")
        }
    }

    private func makeDefault() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            DispatchQueue.main.async {
                if let error {
                    note = "Couldn't change the default browser: \(error.localizedDescription)"
                } else {
                    NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
                    note = "Links from other apps now open in Perch."
                }
            }
        }
    }
}

/// Click, press a shortcut, done. Escape cancels; Delete removes it.
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 3) {
                    if recording {
                        Text("Type a shortcut…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if let combo {
                        ForEach(Array(combo.caps.enumerated()), id: \.offset) { _, cap in Keycap(text: cap) }
                    } else {
                        Text("None")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 110)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: recording ? 1.5 : 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if combo != nil && !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        (NSApp.delegate as? AppDelegate)?.suspendHotKey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Escape
                stop()
            case 51, 117: // Delete, Forward Delete
                combo = nil
                stop()
            default:
                guard let new = KeyCombo(event: event) else { NSSound.beep(); return nil }
                combo = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            (NSApp.delegate as? AppDelegate)?.suspendHotKey(false)
        }
    }
}
