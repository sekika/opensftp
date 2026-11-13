import Foundation

/// Deletes a confirmed folder using SFTP only. Complete enumeration precedes
/// any mutation; files and links are unlinked before their parent directories.
@MainActor
public final class RemoteDeletion {
    private struct Removal {
        let path: String
        let kind: RemoteEntry.Kind
    }
    private let host: String
    private let service: any SFTPRunning
    private let log: (RunResult) -> Void
    private let status: (String) -> Void
    private let limitsOverride: ResourceLimits?
    private var traversalBudget = TraversalBudget()

    public init(host: String, service: any SFTPRunning, limits: ResourceLimits? = nil,
                log: @escaping (RunResult) -> Void, status: @escaping (String) -> Void) {
        self.host = host; self.service = service; self.log = log; self.status = status
        limitsOverride = limits?.validated
    }

    public func removeFolder(at root: String) async throws -> Int {
        traversalBudget = TraversalBudget(limitsOverride ?? .standard)
        try SFTPCommand.validateHost(host)
        try SFTPCommand.validatePath(root)
        let components = root.split(separator: "/")
        guard root.hasPrefix("/"), !components.isEmpty, !root.hasSuffix("/"),
              !root.contains("//"), !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw failure("削除対象にはルート以外のフォルダの絶対パスを指定してください。")
        }
        let parent = (root as NSString).deletingLastPathComponent
        let name = (root as NSString).lastPathComponent
        guard (try await list(parent)).first(where: { $0.name == name })?.isDirectory == true else {
            throw failure("削除対象が通常のフォルダではないか、見つかりません: \(root)")
        }
        status("削除対象を確認中…")
        var plan: [Removal] = []
        try traversalBudget.consume(1)
        try await enumerate(root, depth: 0, plan: &plan)
        var completed = 0
        for removal in plan {
            // A planned directory must still be a directory, including every
            // ancestor below the confirmed root. Never knowingly traverse links.
            try await validateParents(of: removal.path, root: root)
            let directory = (removal.path as NSString).deletingLastPathComponent
            let name = (removal.path as NSString).lastPathComponent
            guard let current = (try await list(directory)).first(where: { $0.name == name }), current.kind == removal.kind else {
                throw failure("削除対象が確認後に変更されました: \(removal.path)。一部の項目は削除済みの可能性があります。")
            }
            status("削除 \(completed)/\(plan.count)件 · \(removal.path)")
            _ = try await command(SFTPCommand.operation(removal.kind == .directory ? "rmdir" : "rm", removal.path))
            completed += 1
        }
        return completed
    }

    private func enumerate(_ directory: String, depth: Int, plan: inout [Removal]) async throws {
        try traversalBudget.checkDepth(depth)
        status("削除対象を確認中：\(directory)")
        let children = try await list(directory)
        try traversalBudget.consume(children.count)
        for child in children.sorted(by: { $0.name < $1.name }) {
            await Task.yield()
            try Task.checkCancellation()
            let path = SFTPCommand.join(directory, child.name)
            if child.isDirectory { try await enumerate(path, depth: depth + 1, plan: &plan) }
            else { plan.append(Removal(path: path, kind: child.kind)) }
        }
        plan.append(Removal(path: directory, kind: .directory))
    }

    private func validateParents(of path: String, root: String) async throws {
        let boundary = (root as NSString).deletingLastPathComponent
        var parent = (path as NSString).deletingLastPathComponent
        var parents: [String] = []
        while parent != boundary {
            guard parent == root || parent.hasPrefix(root + "/") else { throw failure("削除対象が指定範囲外です。") }
            parents.append(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        for directory in parents.reversed() {
            let parent = (directory as NSString).deletingLastPathComponent
            let name = (directory as NSString).lastPathComponent
            guard (try await list(parent)).first(where: { $0.name == name })?.isDirectory == true else {
                throw failure("削除中にフォルダの種類が変更されました: \(directory)。リンク先へは移動しません。")
            }
        }
    }

    private func list(_ directory: String) async throws -> [RemoteEntry] {
        let result = try await command(SFTPCommand.listing(directory))
        let listing = try DirectoryListing.parseChecked(result.stdout, limits: traversalBudget.limits)
        guard listing.path != nil, listing.unparsed.isEmpty else {
            throw failure("削除対象の一覧を完全に解析できません: \(directory)")
        }
        if listing.entries.contains(where: { $0.kind == .symbolicLink }) {
            // Long symlink listings use an ambiguous "name -> target" syntax.
            // Confirm exact names independently before using them in rm.
            let namesResult = try await command(["cd " + SFTPCommand.quote(directory), "ls -1a", "bye"])
            var names = Set<String>()
            for line in LFLineSequence(namesResult.stdout) {
                if line.isEmpty || line.hasPrefix("sftp> ") || line == "." || line == ".." { continue }
                guard names.count < traversalBudget.limits.listingEntries else { throw ResourceLimitError.listing }
                guard (try? SFTPCommand.validateName(line)) != nil, names.insert(line).inserted else {
                    throw failure("リンクの名前を安全に確認できません: \(directory)")
                }
            }
            guard names == Set(listing.entries.map(\.name)) else {
                throw failure("一覧の名前が一致しません。リンクの名前が曖昧か、フォルダが変更されています: \(directory)")
            }
        }
        return listing.entries
    }

    private func command(_ commands: [String]) async throws -> RunResult {
        try Task.checkCancellation()
        let result = await service.run(host: host, commands: commands)
        log(result)
        try Task.checkCancellation()
        if let kind = result.failure {
            throw failure("\(kind.rawValue)。削除を中止しました。一部の項目は削除済みの可能性があります。詳細ログを確認してください。")
        }
        return result
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "OpenSFTP.RemoteDeletion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
