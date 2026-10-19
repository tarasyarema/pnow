import Foundation

/// Posts to dev-null.sh the way `curl -fsSL https://dev-null.sh/commit | bash` does. There is no
/// login: we sign the commit with a local SSH key, and dev-null.sh checks the signature against
/// the public keys GitHub publishes for you.
enum DevNull {
    static let base = URL(string: "https://dev-null.sh")!

    /// Returns the server's answer, which holds the link to the new commit. `replyTo` is the hash
    /// or the link of the commit to reply to.
    static func commit(_ message: String, replyTo: String = "") async throws -> String {
        // It goes on its own line of the signed payload.
        let replyCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:/._@-")
        guard replyTo.unicodeScalars.allSatisfy(replyCharacters.contains) else {
            throw PnowError("A reply takes the hash of a commit or its link.")
        }

        let keys = await Task.detached { SSH.localKeys() }.value
        guard !keys.isEmpty else {
            throw PnowError("No Ed25519 or RSA SSH key found in your SSH agents or in ~/.ssh.")
        }

        // 1. Ask which of our public keys is on the GitHub account of a dev-null.sh user.
        let candidates = keys.map(\.id).joined(separator: "\n") + "\n"
        let answer = try await send("/api/cli/key-lookups", body: Data(candidates.utf8))
        let chosen = answer.split(separator: "\n").first.flatMap { SSH.keyID(String($0)) }
        // Only ever sign with one of our own keys, whatever the server answers.
        guard let key = keys.first(where: { $0.id == chosen }) else {
            throw PnowError("Unexpected answer from dev-null.sh.")
        }

        // 2. Sign "<unix time>\n<nonce>\n<reply to>\n<message>". The reply line is empty for a new post.
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let payload = Data("\(Int(Date().timeIntervalSince1970))\n\(nonce)\n\(replyTo)\n\(message)".utf8)
        let signature = try await Task.detached {
            try SSH.sign(payload, with: key, namespace: "devnull-commit")
        }.value

        // 3. Commit.
        return try await send("/api/cli/commits", body: payload, signature: signature)
    }

    /// A post link, like https://dev-null.sh/@user/commits/<id>, without query or fragment.
    static func postLink(in text: String) -> URL? {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https",
              components.host == base.host(),
              components.path.split(separator: "/").contains("commits")
        else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// "@user’s post 01a155a7"
    static func describe(_ link: URL) -> String {
        let parts = link.pathComponents.filter { $0 != "/" }
        let author = parts.first { $0.hasPrefix("@") }
        let id = parts.last.map { String($0.prefix(8)) } ?? ""
        return author.map { "\($0)’s post \(id)" } ?? "post \(id)"
    }

    private static func send(_ path: String, body: Data, signature: String? = nil) async throws -> String {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let signature {
            request.setValue(signature, forHTTPHeaderField: "X-SSH-Signature")
        }

        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PnowError(text.isEmpty ? "Unexpected answer from dev-null.sh (HTTP \(status))." : text)
        }
        return text
    }
}

/// The signature header must never follow a redirect to another host.
nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
