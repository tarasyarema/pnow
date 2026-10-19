import Carbon.HIToolbox
import Sparkle
import SwiftUI

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let repository = URL(string: "https://github.com/tarasyarema/pnow")!
}

@main
struct PnowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("pnow", systemImage: "paperplane.fill") {
            MenuContent(model: appDelegate.model, newPost: appDelegate.showComposer, checkForUpdates: appDelegate.checkForUpdates)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: ComposerPanel?
    private var hotKey: HotKey?
    private var updater: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        let panel = ComposerPanel(model: model, checkForUpdates: checkForUpdates)
        self.panel = panel
        hotKey = HotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | controlKey) { panel.toggle() }
        panel.show()
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
        guard let url = urls.first(where: { $0.scheme == "pnow" }),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }
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

    var body: some View {
        Button("New Post", action: newPost)
            .keyboardShortcut("p", modifiers: [.command, .control])
        Divider()
        if model.history.posts.isEmpty {
            Text("Nothing posted yet")
        } else {
            ForEach(model.history.posts.prefix(5)) { post in
                Button(post.preview) { post.open() }
            }
        }
        Divider()
        Text("pnow \(AppInfo.version)")
        if let version = model.availableUpdate {
            Button("Update to \(version)…", action: checkForUpdates)
        } else {
            Button("Check for Updates…", action: checkForUpdates)
        }
        Button("pnow on GitHub") { NSWorkspace.shared.open(AppInfo.repository) }
        Divider()
        Button("Quit pnow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
