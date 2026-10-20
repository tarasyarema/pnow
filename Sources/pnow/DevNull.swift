import CryptoKit
import Foundation

/// Posts to dev-null.sh the way `curl -fsSL https://dev-null.sh/commit | bash` does. There is no
/// login: we sign the commit with a local SSH key, and dev-null.sh checks the signature against
/// the public keys GitHub publishes for you.
enum DevNull {
    static let base = URL(string: "https://dev-null.sh")!

    /// Returns the server's answer, which holds the link to the new commit. `replyTo` is the hash
    /// or the link of the commit to reply to.
    static func commit(_ message: String, replyTo: String = "", images: [UploadImage] = []) async throws -> String {
        guard images.count <= Attachments.limit else {
            throw PnowError("A post can carry up to \(Attachments.limit) images.")
        }
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

        // 2. Sign "<unix time>\n<nonce>\n<reply to>\n<message>". The reply line is empty for a new
        // post. With images, a line of their SHA-256 hashes goes before the message.
        let nonce = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        var lines = ["\(Int(Date().timeIntervalSince1970))", nonce, replyTo]
        if !images.isEmpty {
            lines.append(images.map { SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined() }.joined(separator: ","))
        }
        lines.append(message)
        let payload = Data(lines.joined(separator: "\n").utf8)
        let namespace = images.isEmpty ? "devnull-commit" : "devnull-commit-images"
        let signature = try await Task.detached {
            try SSH.sign(payload, with: key, namespace: namespace)
        }.value

        // 3. Commit: the payload is the raw body, or a form part next to the images.
        guard !images.isEmpty else {
            return try await send("/api/cli/commits", body: payload, signature: signature)
        }
        let boundary = "pnow-\(UUID().uuidString)"
        var form = Data()
        func addPart(name: String, filename: String, contentType: String, data: Data) {
            form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
            form.append(data)
            form.append(Data("\r\n".utf8))
        }
        addPart(name: "payload", filename: "commit", contentType: "application/octet-stream", data: payload)
        for (index, image) in images.enumerated() {
            addPart(name: "images[]", filename: "image-\(index + 1).\(image.fileExtension)", contentType: image.mimeType, data: image.data)
        }
        form.append(Data("--\(boundary)--\r\n".utf8))
        return try await send("/api/cli/commits", body: form, contentType: "multipart/form-data; boundary=\(boundary)", signature: signature, timeout: 600)
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
    /// dev-null.sh users for `query`, from the search its website uses. It is not part of the CLI
    /// API, so callers treat a failure as no results.
    static func searchUsers(_ query: String) async throws -> [Handle] {
        struct Found: Decodable {
            struct User: Decodable {
                let username: String
                let name: String?
            }
            let users: [User]
        }
        var search = URLComponents(url: base.appending(path: "search/users"), resolvingAgainstBaseURL: false)!
        search.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: search.url!, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PnowError("dev-null.sh search failed.")
        }
        return try JSONDecoder().decode(Found.self, from: data).users.map { Handle(username: $0.username, name: $0.name) }
    }

    /// "user" in https://dev-null.sh/@user/commits/<id>
    static func author(of link: URL) -> String? {
        link.pathComponents.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) }
    }

    static func describe(_ link: URL) -> String {
        let parts = link.pathComponents.filter { $0 != "/" }
        let author = parts.first { $0.hasPrefix("@") }
        let id = parts.last.map { String($0.prefix(8)) } ?? ""
        return author.map { "\($0)’s post \(id)" } ?? "post \(id)"
    }

    private static func send(
        _ path: String,
        body: Data,
        contentType: String = "text/plain; charset=utf-8",
        signature: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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
