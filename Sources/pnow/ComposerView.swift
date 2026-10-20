import SwiftUI

struct ComposerView: View {
    /// The card plus room around it for the shadow. A margin narrower than the shadow cuts it off
    /// at the window edge, which shows as a faint rectangle on light backgrounds.
    static let windowWidth = cardWidth + 2 * margin
    private static let cardWidth: CGFloat = 720
    private static let margin: CGFloat = 48
    private static let editorFont = Font.system(size: 20)

    @Bindable var model: AppModel
    let checkForUpdates: () -> Void
    let openSettings: () -> Void
    let acceptMention: (Int) -> Void
    let onHeightChange: (CGFloat) -> Void
    @FocusState private var editorFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let target = model.replyingTo {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                    Text("Replying to \(target.title)")
                        .lineLimit(1)
                    Spacer()
                    Keycap("esc")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 23)
                .padding(.top, 14)
                .padding(.bottom, -8)
            }
            editor
            mentions
            attachments
            if case .failed(let message) = model.status {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 23)
                    .padding(.bottom, 12)
            }
            Divider()
            recent
            Divider()
            actionBar
        }
        .frame(width: Self.cardWidth)
        .background { CardBackground() }
        .dropDestination(for: URL.self) { files, _ in
            model.attach(files: files)
            return true
        }
        .padding(Self.margin)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .onChange(of: model.focusTick) { editorFocused = true }
        .onChange(of: model.search == nil) { _, closed in
            if closed { editorFocused = true } else { searchFocused = true }
        }
        .onChange(of: model.draft) { old, _ in model.draftChanged(from: old) }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the editor to its text: one line, up to eight, then it scrolls.
            Text(model.draft + " ")
                .lineLimit(1...8)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
            if model.draft.isEmpty {
                Text(model.replyingTo == nil ? "What did you ship?" : "Write a reply…")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
            }
            TextEditor(text: $model.draft)
                .textEditorStyle(.plain)
                .scrollIndicators(.never)
                .focused($editorFocused)
        }
        .font(Self.editorFont)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// Handles for the "@name" at the caret. ↑ ↓ choose, ⇥ or ↩ picks, esc hides them.
    @ViewBuilder
    private var mentions: some View {
        if let mention = model.mention {
            VStack(spacing: 2) {
                ForEach(Array(mention.handles.enumerated()), id: \.offset) { index, handle in
                    Button { acceptMention(index) } label: {
                        HStack {
                            Text("@\(handle.username)")
                            if let name = handle.name, name.caseInsensitiveCompare(handle.username) != .orderedSame {
                                Text(name)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if index == mention.selected {
                                Keycap("⇥")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == mention.selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 15)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var attachments: some View {
        if !model.attachments.isEmpty {
            HStack(spacing: 10) {
                ForEach(model.attachments) { attachment in
                    Image(nsImage: attachment.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        }
                }
                Spacer()
                Text("\(model.attachments.count) of \(Attachments.limit) images")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 23)
            .padding(.bottom, 14)
        } else if model.clipboardHasImage {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                Text("Image in your clipboard")
                Keycap("⌘V")
                Text("to attach it")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 23)
            .padding(.bottom, 12)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if model.search != nil {
                    Image(systemName: "magnifyingglass")
                    TextField("Search your posts", text: Binding { model.search ?? "" } set: { model.search = $0 })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .focused($searchFocused)
                } else {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                Button(action: model.toggleSearch) {
                    Hint(model.search == nil ? "Search" : "Close", key: "⌘/")
                }
                .buttonStyle(.hover)
                .keyboardShortcut("/", modifiers: .command)
                Button(action: model.replyToCopiedLink) {
                    Hint("Reply to copied link", key: "⌘⇧R")
                }
                .buttonStyle(.hover)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            let posts = model.visiblePosts
            if posts.isEmpty {
                Text(model.search == nil ? "Nothing posted yet." : "No posts match.")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                            RecentRow(
                                post: post,
                                number: index < 5 ? index + 1 : nil,
                                selected: model.selection == index,
                                justPosted: post.id == model.history.posts.first?.id && model.status == .posted
                            ) {
                                model.reply(to: post)
                            }
                            .id(index)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 180)
                .onChange(of: model.selection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
        }
        .padding(8)
    }

    /// Left: where posts go and about pnow. Right: the actions for what has focus, so the list
    /// keys replace the post keys instead of crowding them.
    private var actionBar: some View {
        HStack(spacing: 6) {
            Button { model.cycleDestination() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                    Text(model.destination.label)
                    Keycap("⇥")
                }
            }
            .buttonStyle(.hover)
            .keyboardShortcut("t", modifiers: .command)
            .help("Where it posts. ⇥ or ⌘T switches")
            HStack(spacing: 2) {
                if let version = model.availableUpdate {
                    Button("Update to \(version)", action: checkForUpdates)
                        .buttonStyle(.hover)
                        .foregroundStyle(.tint)
                } else {
                    Text("pnow \(AppInfo.version)")
                        .padding(.horizontal, 6)
                }
                Link(destination: AppInfo.repository) {
                    HStack(spacing: 2) {
                        Text("GitHub")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.hover)
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.hover)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
            }
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)

            Spacer(minLength: 12)

            if model.selection != nil {
                Hint("Open", key: "↩")
                if model.selectedPost?.xLink != nil {
                    Hint("On X", key: "X")
                }
                Hint("Reply", key: "R")
                Hint("Back", key: "esc")
            } else {
                xCounter
                status
                Button(action: replyToLatest) {
                    Hint(model.replyingTo == nil ? "Reply to last" : "Cancel reply", key: "⌘R")
                }
                .buttonStyle(.hover)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.replyingTo == nil && !(model.history.posts.first?.canReply ?? false))
                Button { Task { await model.post() } } label: {
                    Hint("Post", key: "⌘↩")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.hover)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canPost)
                .opacity(model.canPost ? 1 : 0.45)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func replyToLatest() {
        if model.replyingTo != nil {
            model.replyingTo = nil
        } else if let latest = model.history.posts.first {
            model.reply(to: latest)
        }
    }

    /// X's 280 limit, while the post goes there.
    @ViewBuilder
    private var xCounter: some View {
        if model.destination.includesX, !model.draft.isEmpty {
            let length = model.xLength
            Text("\(length)/\(XText.limit)")
                .monospacedDigit()
                .foregroundStyle(length > XText.limit ? AnyShapeStyle(.red) : length > XText.limit - 20 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.status {
        case .idle, .failed:
            EmptyView()
        case .posting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Posting…")
            }
            .fixedSize()
        case .posted:
            Label("Posted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize()
        }
    }
}

private struct RecentRow: View {
    let post: Post
    /// ⌘1 to ⌘5 open the first five rows, ⌥⌘1 to ⌥⌘5 reply to them.
    let number: Int?
    let selected: Bool
    let justPosted: Bool
    let reply: () -> Void
    @State private var hovering = false

    private var showsReply: Bool { hovering || selected }

    var body: some View {
        HStack(spacing: 10) {
            Button { post.open() } label: {
                HStack(spacing: 10) {
                    icon
                        .frame(width: 16)
                    Text(post.preview)
                        .lineLimit(1)
                    if let images = post.imageCount {
                        Label("\(images)", systemImage: "photo")
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12))
                    }
                    Spacer(minLength: 12)
                    Text(post.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .keyboardShortcut(shortcut([.command]))
            .help(post.replyTo == nil ? "Open" : "Open your reply")

            if let xLink = post.xLink {
                Link(destination: xLink) {
                    Text("X")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .background(.quaternary, in: .rect(cornerRadius: 5))
                }
                .help("Open on X")
            }

            // One slot at the right edge: the ⌘ number, or the reply button on hover.
            ZStack {
                if let number {
                    Keycap("⌘\(number)")
                        .opacity(showsReply ? 0 : 1)
                }
                Button(action: reply) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 18)
                        .contentShape(.rect)
                }
                .keyboardShortcut(shortcut([.command, .option]))
                .help(number.map { "Reply (⌥⌘\($0))" } ?? "Reply")
                .disabled(!post.canReply)
                .opacity(showsReply ? 1 : 0)
                .allowsHitTesting(showsReply)
            }
            .frame(width: 32, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(showsReply ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    /// Replies hang off the post they answer.
    @ViewBuilder
    private var icon: some View {
        if justPosted {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if post.replyTo != nil {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "arrow.up.right")
                .foregroundStyle(.tertiary)
        }
    }

    private func shortcut(_ modifiers: EventModifiers) -> KeyboardShortcut? {
        number.map { KeyboardShortcut(KeyEquivalent(Character("\($0)")), modifiers: modifiers) }
    }
}

/// Text buttons and links that light up under the mouse.
private struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var lit: Bool { hovering && isEnabled }

        var body: some View {
            configuration.label
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .brightness(lit ? 0.3 : 0)
                .background(lit ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(.rect)
                .onHover { hovering = $0 }
                .pointerStyle(isEnabled ? .link : nil)
                .animation(.easeOut(duration: 0.12), value: lit)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    fileprivate static var hover: HoverButtonStyle { HoverButtonStyle() }
}

private struct Hint: View {
    let label: String
    let key: String

    init(_ label: String, key: String) {
        self.label = label
        self.key = key
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            Keycap(key)
        }
        .fixedSize()
        .contentShape(.rect)
    }
}

private struct Keycap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 18)
            .background(.quaternary, in: .rect(cornerRadius: 5))
            .fixedSize()
    }
}

/// A heavy behind-window blur with a tint, so text stays readable over any content, plus a soft
/// shadow and a hairline edge.
private struct CardBackground: View {
    private let shape = RoundedRectangle(cornerRadius: 24)

    var body: some View {
        ZStack {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
            Blur()
                .clipShape(shape)
            shape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            shape
                .strokeBorder(.white.opacity(0.14))
        }
    }

    private struct Blur: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }
}
