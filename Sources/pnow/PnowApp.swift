import Carbon.HIToolbox
import Sparkle
import SwiftUI

enum AppInfo {
    /// scripts/build-app.sh marks local builds. They never update themselves.
    static let isDevBuild = Bundle.main.object(forInfoDictionaryKey: "PnowDevBuild") as? Bool ?? true
    static let version = isDevBuild ? "dev" : Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let repository = URL(string: "https://github.com/tarasyarema/pnow")!
}

@main
struct PnowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("pnow", systemImage: "paperplane.fill") {
            MenuContent(
                model: appDelegate.model,
                newPost: appDelegate.showComposer,
                checkForUpdates: appDelegate.checkForUpdates,
                openSettings: appDelegate.showSettings
            )
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: ComposerPanel?
    private var hotKey: HotKey?
    private var updater: SPUStandardUpdaterController?
    private var settingsWindow: NSWindow?
    private var runningApps: NSKeyValueObservation?
    /// Another pnow already runs (for example the local build next to the Homebrew one).
    private var handsOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One pnow at a time: a second launch (Raycast opens /Applications/pnow.app even while
        // the local build runs) passes its request to the running one and quits.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != .current }) {
            handsOff = true
            DistributedNotificationCenter.default().postNotificationName(Self.handOff, object: nil, deliverImmediately: true)
            // Leaves time for a pnow:// URL that launched us to arrive and be passed on too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.handOff, object: nil, queue: .main) { [weak self] notification in
            let url = (notification.userInfo?["url"] as? String).flatMap(URL.init(string:))
            MainActor.assumeIsolated {
                if let url { self?.open(url) } else { self?.showComposer() }
            }
        }
        // Copies from before the hand-off (0.0.2 and older) don't quit by themselves. NSWorkspace
        // posts no launch notification for menu bar apps, so watch the list of running apps.
        runningApps = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let others = (change.newValue ?? []).filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0 != .current }
            guard !others.isEmpty else { return }
            DispatchQueue.main.async {
                others.forEach { $0.forceTerminate() }
                self?.showComposer()
            }
        }

        if !AppInfo.isDevBuild {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        }
        let panel = ComposerPanel(model: model, checkForUpdates: checkForUpdates, openSettings: showSettings)
        self.panel = panel
        register(model.preferences.hotKey)
        model.preferences.onHotKeyChange = { [weak self] combo in self?.register(combo) }
        if model.preferences.showComposerAtLaunch {
            panel.show()
        }
    }

    private func register(_ combo: HotKeyCombo) {
        hotKey?.unregister()
        hotKey = HotKey(combo) { [weak self] in self?.panel?.toggle() }
    }

    func showSettings() {
        panel?.orderOut(nil)
        model.x.reloadClientID()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(preferences: model.preferences, x: model.x)))
            window.title = "pnow Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // A click in another app or a switch to another app closes the composer.
    func applicationDidResignActive(_ notification: Notification) {
        panel?.hide()
    }

    // Opening pnow again (Raycast, Spotlight, Finder, `open -a pnow`) brings up the composer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showComposer()
        return false
    }

    /// For Raycast quicklinks, bookmarklets and scripts:
    /// pnow://new opens the composer, pnow://new?text=... also fills it in,
    /// pnow://reply?to=<post link> opens it as a reply to that post.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "pnow" }) else { return }
        if handsOff {
            DistributedNotificationCenter.default().postNotificationName(Self.handOff, object: nil, userInfo: ["url": url.absoluteString], deliverImmediately: true)
        } else {
            open(url)
        }
    }

    private func open(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = { (name: String) in components.queryItems?.first(where: { $0.name == name })?.value }
        if url.host() == "reply", let link = query("to") {
            model.reply(toLink: link)
        }
        if let text = query("text") {
            model.draft = text
        }
        showComposer()
    }

    func showComposer() {
        panel?.show()
    }

    private static let handOff = Notification.Name("com.tarasyarema.pnow.handOff")

    func checkForUpdates() {
        updater?.checkForUpdates(nil)
    }
}

// pnow lives in the menu bar, so an update found by a scheduled check shows up as a quiet
// "Update to x" in the menu and the composer instead of a window popping up.
extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            // Sparkle's window would open behind the app you are in.
            NSApp.activate()
        } else {
            model.availableUpdate = update.displayVersionString
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        model.availableUpdate = nil
    }
}

struct MenuContent: View {
    let model: AppModel
    let newPost: () -> Void
    let checkForUpdates: () -> Void
    let openSettings: () -> Void

    var body: some View {
        Button("New Post (\(model.preferences.hotKey.label))", action: newPost)
        Divider()
        if model.history.posts.isEmpty {
            Text("Nothing posted yet")
        } else {
            ForEach(model.history.posts.prefix(5)) { post in
                Button(post.shortPreview) { post.open() }
            }
        }
        Divider()
        Text("pnow \(AppInfo.version)")
        if AppInfo.isDevBuild {
            Text("Local build: no updates")
        } else if let version = model.availableUpdate {
            Button("Update to \(version)…", action: checkForUpdates)
        } else {
            Button("Check for Updates…", action: checkForUpdates)
        }
        Button("pnow on GitHub") { NSWorkspace.shared.open(AppInfo.repository) }
        Button("Settings…", action: openSettings)
            .keyboardShortcut(",")
        Divider()
        Button("Quit pnow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
