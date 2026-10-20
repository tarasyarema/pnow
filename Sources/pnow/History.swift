import AppKit
import Observation

struct Post: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// Where it went: "dev-null.sh", "X", or "dev-null.sh + X".
    let target: String
    let text: String
    /// dev-null.sh's answer, kept as-is. Empty when the post went to X only.
    let response: String
    /// The link of the post this one replies to.
    var replyTo: String?
    var imageCount: Int?
    /// The post on X.
    var xLink: URL?

    /// The dev-null.sh post: the first link in its answer.
    var link: URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.firstMatch(in: response, range: NSRange(response.startIndex..., in: response))?.url
    }

    /// The first line. Views truncate it to their width.
    var preview: String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    /// For menu items, which grow to fit their title.
    var shortPreview: String {
        preview.count > 48 ? preview.prefix(47) + "…" : preview
    }

    var canReply: Bool { link != nil || xLink != nil }

    func open() {
        NSWorkspace.shared.open(link ?? xLink ?? DevNull.base)
    }
}

/// Every post, newest first, in ~/Library/Application Support/pnow/history.json. Nothing is fetched.
@Observable
final class History {
    private(set) var posts: [Post] = []
    private let file: URL

    init() {
        let dir = URL.applicationSupportDirectory.appending(path: "pnow", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appending(path: "history.json")

        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let posts = try? decoder.decode([Post].self, from: data) {
            self.posts = posts
        } else {
            // Keep an unreadable file instead of overwriting it on the next post.
            let aside = dir.appending(path: "history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
        }
    }

    /// The handles you mentioned or replied to on dev-null.sh, or on X, most used first. Your own
    /// handle is left out.
    func handles(onX: Bool) -> [String] {
        var seen: [String: (handle: String, count: Int, order: Int)] = [:]
        var own = Set<String>()
        func add(_ handle: String) {
            let order = seen.count
            seen[handle.lowercased(), default: (handle, 0, order)].count += 1
        }
        for post in posts where onX ? post.xLink != nil : post.link != nil {
            let mine = onX ? post.xLink.flatMap { XPostLink($0.absoluteString)?.username } : post.link.flatMap(DevNull.author(of:))
            if let mine { own.insert(mine.lowercased()) }
            Self.mentions(in: post.text).forEach(add)
            if let replyTo = post.replyTo,
               let author = onX ? XPostLink(replyTo)?.username : URL(string: replyTo).flatMap(DevNull.author(of:)) {
                add(author)
            }
        }
        return seen.filter { !own.contains($0.key) }.values
            .sorted { ($0.count, -$0.order) > ($1.count, -$1.order) }
            .map(\.handle)
    }

    /// "@name" that starts a word: not the middle of an email address.
    private static let mention = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_@.-])@([A-Za-z0-9_-]{1,39})")

    private static func mentions(in text: String) -> [String] {
        mention.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func add(_ post: Post) {
        posts.insert(post, at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(posts).write(to: file, options: .atomic)
    }
}
