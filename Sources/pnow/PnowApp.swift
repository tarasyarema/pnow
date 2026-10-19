import Carbon.HIToolbox
import SwiftUI

@main
struct PnowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("pnow", systemImage: "paperplane.fill") {
            MenuContent(model: appDelegate.model, newPost: appDelegate.showComposer)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: ComposerPanel?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = ComposerPanel(model: model)
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
}

struct MenuContent: View {
    let model: AppModel
    let newPost: () -> Void

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
        Button("Quit pnow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
