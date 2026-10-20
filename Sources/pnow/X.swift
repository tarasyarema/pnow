import AppKit
import AuthenticationServices
import CryptoKit
import Observation

/// Posts to X with the official API, as the account you connect in Settings. Each user brings
/// their own X developer app (docs/x-setup.md), and X bills that app for each post (pay per use),
/// so pnow calls the API only when you post.
@Observable
final class XAccount {
    static let guide = URL(string: "https://github.com/tarasyarema/pnow/blob/main/docs/x-setup.md")!
    private static let redirect = "pnow://oauth/x"
    private static let scopes = "tweet.read tweet.write users.read media.write offline.access"
    private static let api = URL(string: "https://api.x.com/2")!
    private static let tokensItem = "x-tokens"
    /// X takes images up to 5 MB.
    private static let maxImageBytes = 5_000_000

    /// The OAuth 2.0 client ID of your X app, a "Native App": it logs in with PKCE and has no
    /// secret. It lives in ~/.config/pnow/config.json.
    private(set) var clientID = ConfigFile.xClientID

    /// The connected handle. It is kept out of the keychain, so a launch reads no secrets.
    private(set) var username = UserDefaults.standard.string(forKey: "xUsername") {
        didSet { UserDefaults.standard.set(username, forKey: "xUsername") }
    }
    private(set) var connecting = false
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    /// One refresh at a time: each one replaces the refresh token, so a second would fail.
    @ObservationIgnored private var refreshing: Task<String, any Error>?
    @ObservationIgnored private let anchor = Anchor()

    var isConnected: Bool { username != nil }

    /// Picks up a client ID edited by hand in the config file.
    func reloadClientID() {
        clientID = ConfigFile.xClientID
    }

    /// A login belongs to one app, so a new client ID logs you out.
    func setClientID(_ text: String) throws {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != (clientID ?? "") else { return }
        try ConfigFile.setXClientID(id.isEmpty ? nil : id)
        clientID = id.isEmpty ? nil : id
        forget()
    }

    /// Logs in with X in a browser sheet. Throws nothing when you cancel.
    func connect() async throws {
        guard let clientID else {
            throw PnowError("Add the client ID of your X app first.")
        }
        connecting = true
        defer { connecting = false }

        let verifier = Self.randomString()
        let state = Self.randomString()
        var authorize = URLComponents(string: "https://x.com/i/oauth2/authorize")!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let callback: URL
        do {
            callback = try await authenticate(authorize.url!)
        } catch ASWebAuthenticationSessionError.canceledLogin {
            return
        }
        let answer = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in answer.first(where: { $0.name == name })?.value }
        if let error = value("error") {
            if error == "access_denied" { return }
            throw PnowError("X login failed: \(error).")
        }
        guard value("state") == state, let code = value("code") else {
            throw PnowError("Unexpected answer from X.")
        }

        let tokens = try await requestTokens([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", Self.redirect),
            ("code_verifier", verifier),
            ("client_id", clientID),
        ])
        try save(tokens)
        let me: Created = try await send(request("users/me", token: tokens.accessToken))
        guard let handle = me.data.username else {
            forget()
            throw PnowError("Unexpected answer from X.")
        }
        username = handle
    }

    /// Revokes the login at X when it can, and forgets it here in any case.
    func disconnect() async {
        if let tokens = savedTokens(), let clientID {
            var request = URLRequest(url: Self.api.appending(path: "oauth2/revoke"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form([("token", tokens.refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientID)])
            _ = try? await URLSession.shared.data(for: request)
        }
        forget()
    }

    /// Returns the link of the new post.
    func post(_ text: String, replyTo: XPostLink?, images: [UploadImage]) async throws -> URL {
        let token = try await accessToken()
        var mediaIDs: [String] = []
        for image in images {
            mediaIDs.append(try await upload(image, token: token))
        }

        var request = request("tweets", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(NewPost(
            text: text,
            media: mediaIDs.isEmpty ? nil : NewPost.Media(media_ids: mediaIDs),
            reply: replyTo.map { NewPost.Reply(in_reply_to_tweet_id: $0.id) }
        ))
        let created: Created = try await send(request)
        return XPostLink(username: username, id: created.data.id).url
    }

    /// X users for `query`, 5 at most: X bills $0.01 for each user a search finds.
    func searchUsers(_ query: String) async throws -> [Handle] {
        struct Found: Decodable {
            struct User: Decodable {
                let username: String
                let name: String?
            }
            let data: [User]?
        }
        let token = try await accessToken()
        var search = URLComponents(url: Self.api.appending(path: "users/search"), resolvingAgainstBaseURL: false)!
        search.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "max_results", value: "5")]
        var request = URLRequest(url: search.url!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let found: Found = try await send(request)
        return (found.data ?? []).map { Handle(username: $0.username, name: $0.name) }
    }

    /// X's API takes replies only in your own threads, or when the author mentions you. Other
    /// replies open X's composer in the browser instead, with the text filled in.
    func canReplyWithAPI(to post: XPostLink) -> Bool {
        guard let username, let author = post.username else { return false }
        return author.caseInsensitiveCompare(username) == .orderedSame
    }

    static func openComposer(_ text: String, replyTo post: XPostLink) {
        var intent = URLComponents(string: "https://x.com/intent/tweet")!
        intent.queryItems = [URLQueryItem(name: "text", value: text), URLQueryItem(name: "in_reply_to", value: post.id)]
        NSWorkspace.shared.open(intent.url!)
    }

    private func upload(_ image: UploadImage, token: String) async throws -> String {
        let maxBytes = Self.maxImageBytes
        let image = try await Task.detached { try image.fitting(maxBytes) }.value
        let boundary = "pnow-\(UUID().uuidString)"
        var form = Data()
        form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"media_category\"\r\n\r\ntweet_image\r\n".utf8))
        form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"image.\(image.fileExtension)\"\r\nContent-Type: \(image.mimeType)\r\n\r\n".utf8))
        form.append(image.data)
        form.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = request("media/upload", token: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
        let uploaded: Uploaded = try await send(request)
        return uploaded.data.id
    }

    // MARK: Tokens

    private struct Tokens: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    /// A fresh access token. It lasts two hours, and each refresh also replaces the refresh token.
    private func accessToken() async throws -> String {
        guard let tokens = savedTokens(), let clientID else {
            forget()
            throw PnowError("Connect your X account in Settings (⌘,).")
        }
        guard tokens.expiresAt < Date().addingTimeInterval(60) else { return tokens.accessToken }
        if let refreshing { return try await refreshing.value }
        let refresh = Task {
            do {
                let fresh = try await requestTokens([
                    ("grant_type", "refresh_token"),
                    ("refresh_token", tokens.refreshToken),
                    ("client_id", clientID),
                ])
                try save(fresh)
                return fresh.accessToken
            } catch let error as XError where error.status == 400 || error.status == 401 {
                forget()
                throw PnowError("Your X login expired. Connect X again in Settings (⌘,).")
            }
        }
        refreshing = refresh
        defer { refreshing = nil }
        return try await refresh.value
    }

    private func requestTokens(_ fields: [(String, String)]) async throws -> Tokens {
        struct Answer: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        var request = URLRequest(url: Self.api.appending(path: "oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let answer: Answer = try await send(request)
        guard let refresh = answer.refresh_token else {
            throw PnowError("X sent no refresh token.")
        }
        return Tokens(accessToken: answer.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(answer.expires_in))
    }

    private func savedTokens() -> Tokens? {
        Keychain.read(Self.tokensItem).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    private func save(_ tokens: Tokens) throws {
        try Keychain.write(JSONEncoder().encode(tokens), to: Self.tokensItem)
    }

    private func forget() {
        Keychain.delete(Self.tokensItem)
        username = nil
    }

    // MARK: HTTP

    private struct NewPost: Encodable {
        struct Media: Encodable { let media_ids: [String] }
        struct Reply: Encodable { let in_reply_to_tweet_id: String }
        let text: String
        let media: Media?
        let reply: Reply?
    }

    /// The answer to creating a post and to users/me.
    private struct Created: Decodable {
        struct Data: Decodable {
            let id: String
            let username: String?
        }
        let data: Data
    }

    private struct Uploaded: Decodable {
        struct Data: Decodable { let id: String }
        let data: Data
    }

    private struct XError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    private func request(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: Self.api.appending(path: path), timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<Answer: Decodable>(_ request: URLRequest) async throws -> Answer {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw XError(status: status, message: Self.describeError(data) ?? "Unexpected answer from X (HTTP \(status)).")
        }
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw PnowError("Unexpected answer from X.")
        }
    }

    /// X answers errors in a few shapes: problem details, an errors list, or OAuth errors.
    private static func describeError(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let first = (json["errors"] as? [[String: Any]])?.first
        let message = json["detail"] ?? first?["detail"] ?? first?["message"] ?? json["error_description"] ?? json["title"] ?? json["error"]
        return message as? String
    }

    // MARK: Login helpers

    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("pnow")) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? PnowError("X login failed."))
                }
            }
            session.presentationContextProvider = anchor
            self.session = session
            session.start()
        }
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }

    private static func randomString() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func form(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }
}

/// An X post, from a link like https://x.com/user/status/123.
struct XPostLink: Equatable {
    let username: String?
    let id: String

    init(username: String?, id: String) {
        self.username = username
        self.id = id
    }

    init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              let host = url.host()?.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "mobile.", with: ""),
              ["x.com", "twitter.com"].contains(host)
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              index + 1 < parts.count,
              parts[index + 1].allSatisfy(\.isNumber)
        else { return nil }
        let author = index > 0 ? parts[index - 1] : nil
        self.init(username: author == "i" || author == "web" ? nil : author, id: parts[index + 1])
    }

    var url: URL {
        URL(string: "https://x.com/\(username ?? "i")/status/\(id)")!
    }

    /// "@user’s post on X"
    var title: String {
        username.map { "@\($0)’s post on X" } ?? "a post on X"
    }
}

enum XText {
    static let limit = 280

    /// The length X counts: most characters 1, CJK and emoji 2, any link 23.
    static func length(_ text: String) -> Int {
        let ns = text as NSString
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var length = 0
        var cursor = 0
        for link in detector?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            length += weight(ns.substring(with: NSRange(location: cursor, length: link.range.location - cursor))) + 23
            cursor = NSMaxRange(link.range)
        }
        return length + weight(ns.substring(from: cursor))
    }

    private static func weight(_ text: String) -> Int {
        text.reduce(0) { sum, character in
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
                return sum + 2
            }
            return sum + scalars.reduce(0) { $0 + (light($1.value) ? 1 : 2) }
        }
    }

    /// The ranges twitter-text counts as 1: Latin, Greek, Cyrillic, Hebrew, Arabic and others,
    /// plus some spaces and punctuation.
    private static func light(_ value: UInt32) -> Bool {
        (0...4351).contains(value) || (8192...8205).contains(value) || (8208...8223).contains(value) || (8242...8247).contains(value)
    }
}

/// Secrets in the login keychain. macOS lets pnow builds signed with the same identity read
/// them without a prompt (scripts/build-app.sh signs local builds with the Developer ID too).
private enum Keychain {
    private static let service = "com.tarasyarema.pnow"

    static func read(_ account: String) -> Data? {
        var result: AnyObject?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, to account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "pnow X login"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PnowError("Could not save the X login in the keychain (\(status)).")
        }
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}
