import Carbon.HIToolbox
import Observation
import ServiceManagement
import SwiftUI

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
    @ObservationIgnored var onHotKeyChange: ((HotKeyCombo) -> Void)?

    init() {
        let saved = UserDefaults.standard.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) }
        hotKey = saved ?? .standard
        showComposerAtLaunch = UserDefaults.standard.object(forKey: "showComposerAtLaunch") as? Bool ?? true
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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            LabeledContent("Open pnow") {
                HotKeyRecorder(combo: $preferences.hotKey)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    preferences.launchAtLogin = enabled
                    launchAtLogin = preferences.launchAtLogin
                }
            Toggle("Show the composer when pnow starts", isOn: $preferences.showComposerAtLaunch)
            LabeledContent("Version") {
                Link("pnow \(AppInfo.version)", destination: AppInfo.repository)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        // pnow has no Dock icon, so the window would open behind the app you are in.
        .onAppear { NSApp.activate() }
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
