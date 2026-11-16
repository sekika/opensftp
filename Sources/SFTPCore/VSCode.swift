import Foundation

/// Arguments for macOS open; paths are never interpreted by a shell.
public struct VSCodeCommand: Sendable {
    public let url: URL
    public let arguments: [String]

    public init(application: URL, host: String, path: String) throws {
        try SFTPCommand.validatePath(host)
        try SFTPCommand.validateHost(host)
        try SFTPCommand.validatePath(path)
        guard path.hasPrefix("/"), application.isFileURL else { throw InputError.invalidPath }

        let parts = host.split(separator: "@", maxSplits: 1).map(String.init)
        let hostname = parts.last!
        let authority: String
        if parts.count == 1, hostname.range(of: #"^[a-z0-9.\-]+$"#, options: .regularExpression) != nil {
            authority = hostname
        } else {
            // Remote-SSH encodes user@host and case-sensitive aliases as hex JSON.
            var connection = ["hostName": hostname.hasPrefix("[") ? String(hostname.dropFirst().dropLast()) : hostname]
            if parts.count == 2 { connection["user"] = parts[0] }
            let data = try JSONSerialization.data(withJSONObject: connection, options: [.sortedKeys])
            authority = data.map { String(format: "%02x", $0) }.joined()
        }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "vscode-remote"
        components.path = "/ssh-remote+\(authority)\(path):1:1"
        guard let url = components.url else { throw InputError.invalidPath }
        self.url = url
        self.arguments = ["-a", application.path, url.absoluteString]
    }
}

public struct VSCodeService: Sendable {
    public init() {}

    public func open(application: URL, host: String, path: String) async throws {
        let command = try VSCodeCommand(application: application, host: host, path: path)
        let result = await SSHProcess.run("/usr/bin/open", command.arguments)
        guard result.succeeded else {
            throw PreviewError("VS Codeを開けませんでした: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
