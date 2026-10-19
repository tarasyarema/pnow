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
    var status = PostStatus.idle
    /// The post the next one replies to.
    var replyingTo: ReplyTarget?
    /// The selected row in Recent, while the keyboard is in the list.
    var selection: Int?
    /// Bumped each time the composer opens, so the editor takes focus.
    var focusTick = 0
    let history = History()

    var canPost: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status != .posting
    }

    func composerOpened() {
        selection = nil
        focusTick += 1
    }

    /// Up from the first row leaves the list.
    func moveSelection(by offset: Int) {
        guard let selection else { return }
        let next = selection + offset
        self.selection = next < 0 ? nil : min(next, history.posts.count - 1)
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
        focusTick += 1
    }

    func post() async {
        guard canPost else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyTo = replyingTo?.link
        status = .posting
        do {
            let response = try await DevNull.commit(text, replyTo: replyTo ?? "")
            history.add(Post(target: "dev-null.sh", text: text, response: response, replyTo: replyTo))
            draft = ""
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
