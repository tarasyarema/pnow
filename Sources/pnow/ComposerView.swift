import SwiftUI

struct ComposerView: View {
    /// The card plus room around it for the shadow.
    static let windowWidth = cardWidth + 2 * margin
    private static let cardWidth: CGFloat = 720
    private static let margin: CGFloat = 28
    private static let editorFont = Font.system(size: 20)

    @Bindable var model: AppModel
    let checkForUpdates: () -> Void
    let onHeightChange: (CGFloat) -> Void
    @FocusState private var editorFocused: Bool

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
        .padding(Self.margin)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .onChange(of: model.focusTick) { editorFocused = true }
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

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: model.replyToCopiedLink) {
                    HStack(spacing: 6) {
                        Text("Reply to copied link")
                        Keycap("⌘⇧R")
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            if model.history.posts.isEmpty {
                Text("Nothing posted yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.history.posts.enumerated()), id: \.element.id) { index, post in
                            RecentRow(
                                post: post,
                                number: index < 5 ? index + 1 : nil,
                                selected: model.selection == index,
                                justPosted: index == 0 && model.status == .posted
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

    private var actionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
            Text("dev-null.sh")
            Text("·")
            if let version = model.availableUpdate {
                Button("Update to \(version)", action: checkForUpdates)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            } else {
                Link("pnow \(AppInfo.version)", destination: AppInfo.repository)
                    .buttonStyle(.plain)
                    .help("pnow on GitHub")
            }
            Spacer()
            status
            if model.selection != nil {
                Hint("Open", key: "↩")
                Hint("Reply", key: "R")
                Hint("Back", key: "esc")
            } else {
                Button(action: replyToLatest) {
                    Hint(model.replyingTo == nil ? "Reply to last" : "Cancel reply", key: "⌘R")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.replyingTo == nil && model.history.posts.first?.link == nil)
            }
            Button { Task { await model.post() } } label: {
                Hint("Post", key: "⌘↩")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canPost)
            .opacity(model.canPost ? 1 : 0.45)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var status: some View {
        switch model.status {
        case .idle, .failed:
            EmptyView()
        case .posting:
            ProgressView()
                .controlSize(.small)
            Text("Posting…")
        case .posted:
            Label("Posted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

private struct RecentRow: View {
    let post: Post
    /// ⌘1 to ⌘5 open the first five posts, ⌥⌘1 to ⌥⌘5 reply to them.
    let number: Int?
    let selected: Bool
    let justPosted: Bool
    let reply: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button { post.open() } label: {
                HStack(spacing: 10) {
                    Image(systemName: justPosted ? "checkmark.circle.fill" : "arrow.up.right")
                        .foregroundStyle(justPosted ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        .frame(width: 16)
                    Text(post.preview)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(post.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .foregroundStyle(.secondary)
                    if let number {
                        Keycap("⌘\(number)")
                    }
                }
                .contentShape(.rect)
            }
            .keyboardShortcut(shortcut([.command]))

            Button(action: reply) {
                Image(systemName: "arrowshape.turn.up.left")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(.rect)
            }
            .keyboardShortcut(shortcut([.command, .option]))
            .help(number.map { "Reply (⌥⌘\($0))" } ?? "Reply")
            .disabled(post.link == nil)
            .opacity(hovering || selected ? 1 : 0)
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering || selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    private func shortcut(_ modifiers: EventModifiers) -> KeyboardShortcut? {
        number.map { KeyboardShortcut(KeyEquivalent(Character("\($0)")), modifiers: modifiers) }
    }
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
        .padding(.leading, 8)
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
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
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
