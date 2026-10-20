import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The floating composer, Raycast-style: showing it activates pnow, and closing it hides pnow so
/// the app you came from gets focus back.
final class ComposerPanel: NSPanel {
    private let model: AppModel
    /// Where esc hid the handles, so they stay hidden while you finish that name.
    private var dismissedMention: Int?

    init(model: AppModel, checkForUpdates: @escaping () -> Void, openSettings: @escaping () -> Void) {
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

        let hostingView = NSHostingView(rootView: ComposerView(model: model, checkForUpdates: checkForUpdates, openSettings: openSettings, acceptMention: { [weak self] in
            self?.acceptMention($0)
        }) { [weak self] height in
            self?.fit(height: height)
        })
        // The panel follows the SwiftUI height itself, keeping its top edge in place.
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleMentionKey(event) || handlePaste(event) || handleTab(event) || handleListKey(event) || handleSearchEscape(event) { return }
        super.sendEvent(event)
        if event.type == .keyDown || event.type == .leftMouseUp { updateMention() }
    }

    /// While handles show: ↑ ↓ choose, ⇥ or ↩ picks, esc hides them.
    private func handleMentionKey(_ event: NSEvent) -> Bool {
        guard let mention = model.mention, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_DownArrow: model.mention?.selected = min(mention.selected + 1, mention.handles.count - 1)
        case kVK_UpArrow: model.mention?.selected = max(mention.selected - 1, 0)
        case kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter: acceptMention()
        case kVK_Escape:
            dismissedMention = mention.range.location
            model.endMention()
        default: return false
        }
        return true
    }

    /// Looks for "@name" right before the caret, at the end of a word.
    private func updateMention() {
        guard model.search == nil, let textView = firstResponder as? NSTextView else {
            model.endMention()
            return
        }
        let caret = textView.selectedRange()
        let text = textView.string as NSString
        let isName = { (index: Int) in
            guard index >= 0, index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "_" || scalar == "-"
        }
        var start = caret.location
        while isName(start - 1) { start -= 1 }
        let at = start - 1
        guard caret.length == 0, at >= 0, text.character(at: at) == 0x40, !isName(at - 1), !isName(caret.location) else {
            model.endMention()
            dismissedMention = nil
            return
        }
        guard at != dismissedMention else {
            model.endMention()
            return
        }
        model.findHandles(
            at: NSRange(location: at, length: caret.location - at),
            prefix: text.substring(with: NSRange(location: start, length: caret.location - start))
        )
    }

    private func acceptMention(_ index: Int? = nil) {
        guard let mention = model.mention, let textView = firstResponder as? NSTextView else { return }
        let name = "@\(mention.handles[index ?? mention.selected].username) "
        if textView.shouldChangeText(in: mention.range, replacementString: name) {
            textView.replaceCharacters(in: mention.range, with: name)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: mention.range.location + (name as NSString).length, length: 0))
        }
        model.endMention()
    }

    /// ⌘V attaches images from the clipboard. Text pastes as usual.
    private func handlePaste(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
            && Int(event.keyCode) == kVK_ANSI_V
            && model.search == nil
            && model.pasteImages()
    }

    /// ⇥ switches where the post goes (⇧⇥ back), in place of typing a tab.
    private func handleTab(_ event: NSEvent) -> Bool {
        guard Int(event.keyCode) == kVK_Tab,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              model.search == nil
        else { return false }
        model.cycleDestination(backwards: event.modifierFlags.contains(.shift))
        return true
    }

    /// The search field would swallow esc.
    private func handleSearchEscape(_ event: NSEvent) -> Bool {
        guard Int(event.keyCode) == kVK_Escape, model.search != nil else { return false }
        model.toggleSearch()
        return true
    }

    /// ↓ at the end of the text moves into Recent. There, ↑ ↓ move, ↩ opens, X opens on X, R
    /// replies, esc goes back, and any other key goes back to the text.
    private func handleListKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let key = Int(event.keyCode)

        guard let selection = model.selection else {
            guard key == kVK_DownArrow, caretAtEnd, !model.visiblePosts.isEmpty else { return false }
            model.selection = 0
            return true
        }

        let post = model.visiblePosts[selection]
        switch key {
        case kVK_DownArrow: model.moveSelection(by: 1)
        case kVK_UpArrow: model.moveSelection(by: -1)
        case kVK_Return, kVK_ANSI_KeypadEnter: post.open()
        case kVK_ANSI_R: model.reply(to: post)
        case kVK_ANSI_X: if let xLink = post.xLink { NSWorkspace.shared.open(xLink) }
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

    // Esc: cancel a reply first, then close. The text and images stay for next time.
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
