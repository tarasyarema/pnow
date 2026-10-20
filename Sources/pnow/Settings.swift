import Carbon.HIToolbox
import Observation
import ServiceManagement
import SwiftUI

/// ~/.config/pnow/config.json, for what you may want in your dotfiles. For now, the client ID
/// of your X app: {"x": {"clientID": "..."}}. Other keys stay as they are.
enum ConfigFile {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/pnow/config.json")

    static var xClientID: String? {
        let id = ((try? read())?["x"] as? [String: Any])?["clientID"] as? String
        return id?.isEmpty == false ? id : nil
    }

    static func setXClientID(_ id: String?) throws {
        var json = try read()
        var x = json["x"] as? [String: Any] ?? [:]
        x["clientID"] = id
        json["x"] = x
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    /// Empty when there is no file. Throws when the file is not valid JSON, so pnow never
    /// overwrites a file you are editing.
    private static func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PnowError("~/.config/pnow/config.json is not valid JSON.")
        }
        return json
    }
}

struct HotKeyCombo: Codable, Equatable {
    static let standard = HotKeyCombo(keyCode: kVK_ANSI_P, carbonModifiers: controlKey | cmdKey, label: "⌃⌘P")

    let keyCode: Int
    let carbonModifiers: Int
    let label: String

    init(keyCode: Int, carbonModifiers: Int, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }

    /// Nil without a modifier other than ⇧: a hotkey must not eat plain typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.subtracting(.shift).isEmpty else { return nil }

        var modifiers = 0
        var label = ""
        for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")]
        where flags.contains(flag) {
            modifiers |= carbon
            label += symbol
        }
        switch Int(event.keyCode) {
        case kVK_Space: label += "Space"
        case kVK_Return: label += "↩"
        case kVK_Tab: label += "⇥"
        default: label += (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        self.init(keyCode: Int(event.keyCode), carbonModifiers: modifiers, label: label)
    }
}

/// The few things you can change, kept in UserDefaults.
@Observable
final class Preferences {
    var hotKey: HotKeyCombo {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey")
            onHotKeyChange?(hotKey)
        }
    }
    var showComposerAtLaunch: Bool {
        didSet { UserDefaults.standard.set(showComposerAtLaunch, forKey: "showComposerAtLaunch") }
    }
    /// Typing @ while posting to X searches X users, which X bills.
    var searchXUsers: Bool {
        didSet { UserDefaults.standard.set(searchXUsers, forKey: "searchXUsers") }
    }
    /// Where new posts go. ⇥ and ⌘T change it.
    var destination: Destination {
        didSet { UserDefaults.standard.set(destination.rawValue, forKey: "destination") }
    }
    @ObservationIgnored var onHotKeyChange: ((HotKeyCombo) -> Void)?

    init() {
        let saved = UserDefaults.standard.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) }
        hotKey = saved ?? .standard
        showComposerAtLaunch = UserDefaults.standard.object(forKey: "showComposerAtLaunch") as? Bool ?? true
        destination = UserDefaults.standard.string(forKey: "destination").flatMap(Destination.init(rawValue:)) ?? .devNull
        searchXUsers = UserDefaults.standard.object(forKey: "searchXUsers") as? Bool ?? true
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let x: XAccount
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var xError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Open pnow") {
                    HotKeyRecorder(combo: $preferences.hotKey)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        preferences.launchAtLogin = enabled
                        launchAtLogin = preferences.launchAtLogin
                    }
                Toggle("Show the composer when pnow starts", isOn: $preferences.showComposerAtLaunch)
            }
            Section {
                LabeledContent("X client ID") {
                    // Saved as you type: the window may close without a return.
                    TextField("X client ID", text: Binding { x.clientID ?? "" } set: { id in
                        do {
                            try x.setClientID(id)
                            xError = nil
                        } catch {
                            xError = error.localizedDescription
                        }
                    }, prompt: Text("Paste it here"))
                    .labelsHidden()
                }
                LabeledContent("X account") {
                    if let username = x.username {
                        HStack {
                            Text("@\(username)")
                            Button("Disconnect") {
                                Task { await x.disconnect() }
                            }
                        }
                    } else {
                        Button(x.connecting ? "Waiting for X…" : "Connect", action: connectX)
                            .disabled(x.connecting || x.clientID == nil)
                    }
                }
                Toggle("Search X users when you type @ (about $0.05 a search)", isOn: $preferences.searchXUsers)
                if let xError {
                    Text(xError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text("X")
                    Spacer()
                    Link("How to get a client ID ↗", destination: XAccount.guide)
                        .font(.callout)
                }
            } footer: {
                Text("pnow posts through your own X app, and X bills it for each post. The client ID is saved in ~/.config/pnow/config.json. Press ⇥ or ⌘T in the composer to post to dev-null.sh, X, or both.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version") {
                    Link("pnow \(AppInfo.version)", destination: AppInfo.repository)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        // pnow has no Dock icon, so the window would open behind the app you are in.
        .onAppear { NSApp.activate() }
    }

    private func connectX() {
        xError = nil
        Task {
            do {
                try await x.connect()
            } catch {
                xError = error.localizedDescription
            }
        }
    }
}

private struct HotKeyRecorder: View {
    @Binding var combo: HotKeyCombo
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? combo.label : "Press a shortcut…") {
            monitor == nil ? record() : stop()
        }
        .monospaced()
        .onDisappear(perform: stop)
    }

    private func record() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if Int(event.keyCode) == kVK_Escape {
                    stop()
                } else if let combo = HotKeyCombo(event: event) {
                    self.combo = combo
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
