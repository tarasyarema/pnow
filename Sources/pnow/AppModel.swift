import AppKit
import Observation

enum PostStatus: Equatable {
    case idle
    case posting
    case posted
    case failed(String)
}

/// Where a post goes.
enum Destination: String, CaseIterable {
    case devNull, x, both

    var includesDevNull: Bool { self != .x }
    var includesX: Bool { self != .devNull }

    var label: String {
        switch self {
        case .devNull: "dev-null.sh"
        case .x: "X"
        case .both: "dev-null.sh + X"
        }
    }
}

/// Someone to mention: a handle, and the name a search found with it.
struct Handle: Equatable {
    let username: String
    var name: String?
}

/// The "@name" being typed at the caret, and the handles that complete it.
struct Mention: Equatable {
    /// The "@" and the letters typed so far.
    let range: NSRange
    let handles: [Handle]
    var selected = 0
}

struct ReplyTarget: Equatable {
    /// The post on dev-null.sh.
    var devNull: URL?
    /// The post on X.
    var x: XPostLink?
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
    var replyingTo: ReplyTarget? {
        didSet { destinationOverride = nil }
    }
    /// Nil when Recent shows the latest posts, the search text while it searches all of them.
    var search: String? {
        didSet { selection = nil }
    }
    /// The selected row in Recent, while the keyboard is in the list.
    var selection: Int?
    var mention: Mention?
    /// The "@name" at the caret, also while it has no handles yet.
    @ObservationIgnored private var mentionQuery: (range: NSRange, prefix: String)?
    @ObservationIgnored private var mentionSearch: Task<Void, Never>?
    /// Search results for this session, so the same letters never cost a second X search.
    @ObservationIgnored private var searchCache: [String: [Handle]] = [:]
    /// Set when the composer opens: the clipboard holds an image that ⌘V would attach.
    var clipboardHasImage = false
    /// Bumped each time the composer opens, so the editor takes focus.
    var focusTick = 0
    /// The version of a newer release, once Sparkle finds one.
    var availableUpdate: String?
    let history = History()
    let preferences = Preferences()
    let x = XAccount()
    /// Where this one post goes, for a reply, or to retry where a post failed.
    private var destinationOverride: Destination?

    static let recentCount = 5

    var canPost: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status != .posting && !overXLimit
    }

    /// The places this post can go: a reply only where its post is, and X once you connect it.
    var destinations: [Destination] {
        let devNull = replyingTo.map { $0.devNull != nil } ?? true
        // Replies to other people's X posts open X in the browser, so they need no login.
        let x = replyingTo.map { $0.x != nil } ?? self.x.isConnected
        switch (devNull, x) {
        case (true, true): return Destination.allCases
        case (true, false): return [.devNull]
        case (false, true): return [.x]
        case (false, false): return []
        }
    }

    var destination: Destination {
        let options = destinations
        if let destinationOverride, options.contains(destinationOverride) { return destinationOverride }
        if options.contains(preferences.destination) { return preferences.destination }
        return options.first ?? .devNull
    }

    /// ⇥ and ⌘T. The choice sticks for new posts, and lasts one post for a reply.
    func cycleDestination(backwards: Bool = false) {
        let options = destinations
        guard options.count > 1 else {
            status = .failed(replyingTo == nil
                ? "Connect your X account in Settings (⌘,) to post there too."
                : "This reply can only go to \(destination.label).")
            return
        }
        let index = options.firstIndex(of: destination) ?? 0
        let next = options[(index + (backwards ? options.count - 1 : 1)) % options.count]
        if replyingTo != nil || destinationOverride != nil {
            destinationOverride = next
        } else {
            preferences.destination = next
        }
    }

    /// The length X counts, against its 280 limit.
    var xLength: Int {
        XText.length(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var overXLimit: Bool {
        destination.includesX && xLength > XText.limit
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

    /// Handles for "@" + `prefix` on the one place this post goes: the ones in your history first,
    /// then a search there. None for posts to both: the same person often has another handle on X.
    func findHandles(at range: NSRange, prefix: String) {
        if let query = mentionQuery, query.range == range, query.prefix == prefix { return }
        let sameName = mentionQuery?.range.location == range.location
        mentionQuery = (range, prefix)
        mentionSearch?.cancel()
        guard destination != .both else {
            mention = nil
            return
        }

        let onX = destination == .x
        let key = "\(onX ? "x" : "dev-null"):\(prefix.lowercased())"
        let local = history.handles(onX: onX)
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            .map { Handle(username: $0) }
        showHandles(local + (searchCache[key] ?? []), at: range, prefix: prefix, keepSelection: sameName)

        // X bills each user a search finds, so it waits for 2 letters and a pause in typing.
        guard searchCache[key] == nil, onX ? prefix.count >= 2 && x.isConnected && preferences.searchXUsers : !prefix.isEmpty else { return }
        mentionSearch = Task {
            try? await Task.sleep(for: .milliseconds(onX ? 400 : 150))
            guard !Task.isCancelled else { return }
            guard let found = try? await (onX ? x.searchUsers(prefix) : DevNull.searchUsers(prefix)) else { return }
            searchCache[key] = found
            guard !Task.isCancelled, mentionQuery?.range == range else { return }
            showHandles(local + found, at: range, prefix: prefix, keepSelection: true)
        }
    }

    func endMention() {
        mentionQuery = nil
        mentionSearch?.cancel()
        mention = nil
    }

    /// Without your own handle, without repeats, and without the name you already typed in full.
    private func showHandles(_ handles: [Handle], at range: NSRange, prefix: String, keepSelection: Bool) {
        let own = destination == .x ? x.username : history.posts.lazy.compactMap { $0.link.flatMap(DevNull.author(of:)) }.first
        var seen: Set<String> = [prefix.lowercased(), own?.lowercased() ?? ""]
        let list = Array(handles.filter { seen.insert($0.username.lowercased()).inserted }.prefix(6))
        guard !list.isEmpty else {
            mention = nil
            return
        }
        mention = Mention(range: range, handles: list, selected: keepSelection ? min(mention?.selected ?? 0, list.count - 1) : 0)
    }

    func composerOpened() {
        selection = nil
        endMention()
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

    /// Only posts with a link can get replies: the link names the post.
    func reply(to post: Post) {
        guard post.canReply else { return }
        let x = post.xLink.flatMap { XPostLink($0.absoluteString) }
        startReply(ReplyTarget(devNull: post.link, x: x, title: "“\(post.preview)”"))
    }

    /// Replies to any dev-null.sh or X post by its link. Returns false when `text` is not one.
    @discardableResult
    func reply(toLink text: String) -> Bool {
        if let link = DevNull.postLink(in: text) {
            if let mine = history.posts.first(where: { $0.link == link }) {
                reply(to: mine)
            } else {
                startReply(ReplyTarget(devNull: link, title: DevNull.describe(link)))
            }
            return true
        }
        if let post = XPostLink(text) {
            if let mine = history.posts.first(where: { $0.xLink.flatMap { XPostLink($0.absoluteString) }?.id == post.id }) {
                reply(to: mine)
            } else {
                startReply(ReplyTarget(x: post, title: post.title))
            }
            return true
        }
        return false
    }

    func replyToCopiedLink() {
        if !reply(toLink: NSPasteboard.general.string(forType: .string) ?? "") {
            status = .failed("Copy the link of a dev-null.sh or X post first.")
        }
    }

    /// Typing leaves the list, and a pasted post link becomes the reply target instead of text.
    func draftChanged(from old: String) {
        if !draft.isEmpty { selection = nil }
        // Clearing the text ends a retry on one place only.
        if draft.isEmpty, replyingTo == nil { destinationOverride = nil }
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

    /// Posts to each place at once. When one of two fails, the text stays, set to go only there.
    func post() async {
        guard canPost else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = replyingTo
        let destination = destination
        let images = attachments.map(\.upload)
        status = .posting

        async let devNullResult = postToDevNull(destination.includesDevNull, text, replyTo: reply?.devNull, images: images)
        async let xResult = postToX(destination.includesX, text, replyTo: reply?.x, images: images)
        let (devNull, x) = await (devNullResult, xResult)

        var response = ""
        var xLink: URL?
        var failed: [(Destination, String)] = []
        switch devNull {
        case .success(let answer): response = answer
        case .failure(let error): failed.append((.devNull, error.localizedDescription))
        case nil: break
        }
        switch x {
        case .success(let link): xLink = link
        case .failure(let error): failed.append((.x, error.localizedDescription))
        case nil: break
        }

        let postedTo = [response.isEmpty ? nil : "dev-null.sh", xLink == nil ? nil : "X"].compactMap { $0 }
        if !postedTo.isEmpty {
            history.add(Post(
                target: postedTo.joined(separator: " + "),
                text: text,
                response: response,
                replyTo: reply?.devNull?.absoluteString ?? reply?.x?.url.absoluteString,
                imageCount: images.isEmpty ? nil : images.count,
                xLink: xLink
            ))
        }

        if failed.isEmpty {
            endMention()
            draft = ""
            attachments = []
            replyingTo = nil
            // Nothing posted here when X opened in the browser.
            status = postedTo.isEmpty ? .idle : .posted
        } else if destination == .both, failed.count == 1, let (place, message) = failed.first {
            destinationOverride = place
            let done = place == .x ? "dev-null.sh" : "X"
            status = .failed("Posted to \(done). \(place.label) failed: \(message) ⌘↩ posts to \(place.label) only.")
        } else {
            status = .failed(failed.map { destination == .both ? "\($0.0.label): \($0.1)" : $0.1 }.joined(separator: "\n"))
        }
    }

    private func postToDevNull(_ enabled: Bool, _ text: String, replyTo: URL?, images: [UploadImage]) async -> Result<String, any Error>? {
        guard enabled else { return nil }
        do {
            return .success(try await DevNull.commit(text, replyTo: replyTo?.absoluteString ?? "", images: images))
        } catch {
            return .failure(error)
        }
    }

    /// A nil link: X opened in the browser, because the API refuses that reply.
    private func postToX(_ enabled: Bool, _ text: String, replyTo: XPostLink?, images: [UploadImage]) async -> Result<URL?, any Error>? {
        guard enabled else { return nil }
        if let replyTo, !x.canReplyWithAPI(to: replyTo) {
            // X's composer has no way to take images from a link: they go on the clipboard for ⌘V.
            if !images.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(images.compactMap { NSImage(data: $0.data) })
            }
            XAccount.openComposer(text, replyTo: replyTo)
            return .success(nil)
        }
        do {
            return .success(try await x.post(text, replyTo: replyTo, images: images))
        } catch {
            return .failure(error)
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
