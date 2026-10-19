import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The floating composer, Raycast-style: showing it activates pnow, and closing it hides pnow so
/// the app you came from gets focus back.
final class ComposerPanel: NSPanel {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: ComposerView.windowWidth, height: 200),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // The window shadow draws a dark hairline around the card. The glass has its own edge.
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        let hostingView = NSHostingView(rootView: ComposerView(model: model) { [weak self] height in
            self?.fit(height: height)
        })
        // The panel follows the SwiftUI height itself, keeping its top edge in place.
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleListKey(event) { return }
        super.sendEvent(event)
    }

    /// ↓ at the end of the text moves into Recent. There, ↑ ↓ move, ↩ opens, R replies, esc goes
    /// back, and any other key goes back to the text.
    private func handleListKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let key = Int(event.keyCode)

        guard let selection = model.selection else {
            guard key == kVK_DownArrow, caretAtEnd, !model.history.posts.isEmpty else { return false }
            model.selection = 0
            return true
        }

        let post = model.history.posts[selection]
        switch key {
        case kVK_DownArrow: model.moveSelection(by: 1)
        case kVK_UpArrow: model.moveSelection(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter: post.open()
        case kVK_ANSI_R: model.reply(to: post)
        case kVK_Escape: model.selection = nil
        default:
            model.selection = nil
            return false
        }
        return true
    }

    private var caretAtEnd: Bool {
        guard let textView = firstResponder as? NSTextView else { return false }
        let range = textView.selectedRange()
        return range.length == 0 && range.location == (textView.string as NSString).length
    }

    // Esc: cancel a reply first, then close.
    override func cancelOperation(_ sender: Any?) {
        if model.replyingTo != nil {
            model.replyingTo = nil
        } else {
            hide()
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        moveToActiveScreen()
        NSApp.activate()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        model.composerOpened()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        // Give focus back to the app you came from.
        if NSApp.isActive { NSApp.hide(nil) }
    }

    /// Grows and shrinks around its center, so it stays centered as the text grows.
    private func fit(height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var frame = frame
        frame.origin.y = frame.midY - height / 2
        frame.size.height = height
        setFrame(frame, display: true)
    }

    /// Centered on the screen that has the mouse.
    private func moveToActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }
}
