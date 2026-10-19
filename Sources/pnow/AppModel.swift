import AppKit
import Observation

enum PostStatus: Equatable {
    case idle
    case posting
    case posted
    case failed(String)
}

struct ReplyTarget: Equatable {
    let link: String
    /// Your post's first line, or the author and id of someone else's post.
    let title: String
}

@Observable
final class AppModel {
    var draft = "" {
        didSet { if status != .posting { status = .idle } }
    }
    var attachments: [Attachment] = []
    var status = PostStatus.idle
    /// The post the next one replies to.
    var replyingTo: ReplyTarget?
    /// Nil when Recent shows the latest posts, the search text while it searches all of them.
    var search: String? {
        didSet { selection = nil }
    }
    /// The selected row in Recent, while the keyboard is in the list.
    var selection: Int?
    /// Set when the composer opens: the clipboard holds an image that ⌘V would attach.
    var clipboardHasImage = false
    /// Bumped each time the composer opens, so the editor takes focus.
    var focusTick = 0
    /// The version of a newer release, once Sparkle finds one.
    var availableUpdate: String?
    let history = History()
    let preferences = Preferences()

    static let recentCount = 5

    var canPost: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status != .posting
    }

    /// The latest posts, or every post that matches the search.
    var visiblePosts: [Post] {
        guard let search else { return Array(history.posts.prefix(Self.recentCount)) }
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? history.posts : history.posts.filter { $0.text.localizedStandardContains(query) }
    }

    var selectedPost: Post? {
        selection.flatMap { visiblePosts.indices.contains($0) ? visiblePosts[$0] : nil }
    }

    func composerOpened() {
        selection = nil
        clipboardHasImage = Attachments.clipboardHasImage()
        focusTick += 1
    }

    /// Up from the first row leaves the list.
    func moveSelection(by offset: Int) {
        guard let selection else { return }
        let next = selection + offset
        self.selection = next < 0 ? nil : min(next, visiblePosts.count - 1)
    }

    func toggleSearch() {
        search = search == nil ? "" : nil
        if search == nil { focusTick += 1 }
    }

    /// Only posts with a link can get replies: the link names the commit.
    func reply(to post: Post) {
        guard let link = post.link else { return }
        startReply(ReplyTarget(link: link.absoluteString, title: "“\(post.preview)”"))
    }

    /// Replies to any dev-null.sh post by its link. Returns false when `text` is not one.
    @discardableResult
    func reply(toLink text: String) -> Bool {
        guard let link = DevNull.postLink(in: text) else { return false }
        if let mine = history.posts.first(where: { $0.link == link }) {
            reply(to: mine)
        } else {
            startReply(ReplyTarget(link: link.absoluteString, title: DevNull.describe(link)))
        }
        return true
    }

    func replyToCopiedLink() {
        if !reply(toLink: NSPasteboard.general.string(forType: .string) ?? "") {
            status = .failed("Copy the link of a dev-null.sh post first.")
        }
    }

    /// Typing leaves the list, and a pasted post link becomes the reply target instead of text.
    func draftChanged(from old: String) {
        if !draft.isEmpty { selection = nil }
        if old.isEmpty, replyingTo == nil, reply(toLink: draft) {
            draft = ""
        }
    }

    private func startReply(_ target: ReplyTarget) {
        replyingTo = target
        selection = nil
        search = nil
        focusTick += 1
    }

    /// Attaches the clipboard's images. Returns false when it holds none, so the paste goes on as text.
    func pasteImages() -> Bool {
        guard Attachments.clipboardHasImage() else { return false }
        attach { try Attachments.read(from: .general) }
        clipboardHasImage = false
        return true
    }

    func attach(files: [URL]) {
        attach { try files.map(Attachments.attachment(fromFile:)) }
    }

    private func attach(_ read: () throws -> [Attachment]) {
        do {
            let new = try read()
            let room = Attachments.limit - attachments.count
            attachments += new.prefix(room)
            if new.count > room {
                status = .failed("A post can carry up to \(Attachments.limit) images.")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func post() async {
        guard canPost else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyTo = replyingTo?.link
        let images = attachments.map(\.upload)
        status = .posting
        do {
            let response = try await DevNull.commit(text, replyTo: replyTo ?? "", images: images)
            history.add(Post(target: "dev-null.sh", text: text, response: response, replyTo: replyTo, imageCount: images.isEmpty ? nil : images.count))
            draft = ""
            attachments = []
            replyingTo = nil
            status = .posted
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

nonisolated struct PnowError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
