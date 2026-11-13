import Foundation

public enum InputError: LocalizedError {
    case invalidHost, invalidPath, invalidName
    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "接続先は Host 名または user@host で入力してください。オプション、URL、ポート・パス指定は使用できません。"
        case .invalidPath: return "パスに改行、NUL、制御文字は使用できません。"
        case .invalidName: return "名前は空欄、.、..、スラッシュを含む値にできません。"
        }
    }
}

public enum SFTPCommand {
    public static func validateHost(_ host: String) throws {
        // Deliberately exclude destination URLs and host:path forms, as well as options.
        let pattern = #"^(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|\[[0-9A-Fa-f:]+\])$"#
        guard host.range(of: pattern, options: .regularExpression) != nil else { throw InputError.invalidHost }
    }

    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw InputError.invalidPath
        }
    }

    public static func validateName(_ name: String) throws {
        try validatePath(name)
        guard name != ".", name != "..", !name.contains("/") else { throw InputError.invalidName }
    }

    /// OpenSSH's batch tokenizer protects glob metacharacters inside double quotes.
    /// Do not add an extra glob escape: that would change the filename.
    public static func quote(_ path: String) throws -> String {
        try validatePath(path)
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    public static func listing(_ path: String?) throws -> [String] {
        var commands: [String] = []
        if let path { commands.append("cd " + (try quote(path))) }
        commands += ["pwd", "ls -la", "bye"]
        return commands
    }

    public static func operation(_ verb: String, _ paths: String...) throws -> [String] {
        precondition(["mkdir", "rename", "rm", "rmdir", "get", "put"].contains(verb))
        return [verb + " " + (try paths.map(quote).joined(separator: " ")), "bye"]
    }

    public static func transfer(_ verb: String, _ source: String, _ destination: String) throws -> [String] {
        precondition(verb == "get" || verb == "put")
        return [verb + " -p " + (try quote(source)) + " " + (try quote(destination)), "bye"]
    }

    public static func symbolicLink(target: String, path: String) throws -> [String] {
        // End option parsing so leading '-' targets retain their exact text.
        ["ln -s -- " + (try quote(target)) + " " + (try quote(path)), "bye"]
    }
}

public enum SSHConfig {
    public static func hosts(in text: String) -> [String] {
        var hosts = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = String(raw.prefix { $0 != "#" })
            // Support Host=value and quoted literal aliases, without interpreting Include/Match.
            guard let directive = line.range(of: #"^\s*(?i:Host)(?:\s*=\s*|\s+)"#, options: .regularExpression) else { continue }
            let tokens = line[directive.upperBound...].split(whereSeparator: { $0.isWhitespace })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            for host in tokens where !host.contains(where: { "*?![]".contains($0) }) {
                if (try? SFTPCommand.validateHost(host)) != nil { hosts.insert(host) }
            }
        }
        return hosts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
