import Foundation

nonisolated struct LocalKey: Sendable {
    /// "<type> <base64>", the form dev-null.sh matches against GitHub.
    let id: String
    /// The agent that holds the private key, if one does.
    let agentSocket: String?
    /// The private key next to a ~/.ssh/*.pub, used when no agent has the key.
    let privateKeyFile: String?
}

/// Thin wrappers around the system ssh tools. These calls block, so run them off the main actor.
nonisolated enum SSH {
    /// Agent keys first, then ~/.ssh/*.pub files that have a private key next to them.
    static func localKeys() -> [LocalKey] {
        var keys: [LocalKey] = []
        func add(_ line: String, agentSocket: String?, privateKeyFile: String?) {
            guard let id = keyID(line), !keys.contains(where: { $0.id == id }) else { return }
            keys.append(LocalKey(id: id, agentSocket: agentSocket, privateKeyFile: privateKeyFile))
        }

        for socket in agentSockets() {
            let listed = (try? run("/usr/bin/ssh-add", ["-L"], agentSocket: socket).stdout) ?? ""
            for line in listed.split(separator: "\n") {
                add(String(line), agentSocket: socket, privateKeyFile: nil)
            }
        }

        let sshDir = URL.homeDirectory.appending(path: ".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(at: sshDir, includingPropertiesForKeys: nil)) ?? []
        for pub in files.filter({ $0.pathExtension == "pub" }).sorted(by: { $0.path < $1.path }) {
            let privateKey = pub.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: privateKey.path),
                  let line = try? String(contentsOf: pub, encoding: .utf8).split(separator: "\n").first
            else { continue }
            add(String(line), agentSocket: nil, privateKeyFile: privateKey.path)
        }
        return keys
    }

    /// Returns the base64 signature of `payload`, as `ssh-keygen -Y sign` makes it.
    static func sign(_ payload: Data, with key: LocalKey, namespace: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pnow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let commit = dir.appending(path: "commit")
        try payload.write(to: commit)

        // Given a public key, ssh-keygen signs through the agent.
        let keyFile: String
        if key.agentSocket != nil {
            let pub = dir.appending(path: "key.pub")
            try Data("\(key.id)\n".utf8).write(to: pub)
            keyFile = pub.path
        } else if let privateKeyFile = key.privateKeyFile {
            keyFile = privateKeyFile
        } else {
            throw PnowError("No private key for \(key.id.prefix(24))…")
        }

        let result = try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", namespace, "-f", keyFile, commit.path], agentSocket: key.agentSocket)
        guard result.status == 0 else {
            if key.agentSocket == nil {
                // There is no terminal to ask for a passphrase.
                throw PnowError("Could not sign with \(keyFile). If it has a passphrase, add it to your agent: ssh-add --apple-use-keychain \(keyFile)")
            }
            throw PnowError("Could not sign with your SSH agent: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let armored = try String(contentsOf: dir.appending(path: "commit.sig"), encoding: .utf8)
        let signature = armored.split(separator: "\n").filter { !$0.contains("-----") }.joined()
        let base64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard !signature.isEmpty, signature.unicodeScalars.allSatisfy(base64.contains) else {
            throw PnowError("ssh-keygen produced an unexpected signature.")
        }
        return signature
    }

    /// "<type> <base64>" for Ed25519 and RSA keys, without the comment.
    static func keyID(_ line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519" || parts[0] == "ssh-rsa" else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    /// GUI apps don't get SSH_AUTH_SOCK from your shell profile, so agents set with IdentityAgent
    /// in ~/.ssh/config (1Password, Secretive, ...) come from ssh's resolved config.
    private static func agentSockets() -> [String] {
        var sockets: [String] = []
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !socket.isEmpty {
            sockets.append(socket)
        }
        let config = (try? run("/usr/bin/ssh", ["-G", "github.com"]).stdout) ?? ""
        for line in config.split(separator: "\n") where line.hasPrefix("identityagent ") {
            let value = String(line.dropFirst("identityagent ".count))
            guard value != "none", value != "SSH_AUTH_SOCK", !value.hasPrefix("$") else { continue }
            let socket = NSString(string: value).expandingTildeInPath
            if !sockets.contains(socket) { sockets.append(socket) }
        }
        return sockets
    }

    private struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ tool: String, _ arguments: [String], agentSocket: String? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let agentSocket {
            environment["SSH_AUTH_SOCK"] = agentSocket
        }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // These tools print little, so reading one pipe to the end can't block on the other.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
    }
}
