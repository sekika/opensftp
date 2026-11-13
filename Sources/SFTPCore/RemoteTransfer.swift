import Foundation

public enum RemoteFileConflictChoice: Sendable { case overwrite, keepBoth, cancel }
public struct RemoteFileConflict: Sendable {
    public let destination: RemoteEndpoint
    public let alternative: String
    public let canOverwrite: Bool
}

/// One complete remote-to-remote job, planned before its first write. File
/// contents are relayed by scp; exact metadata and links stay in SFTP.
@MainActor
public final class RemoteTransfer {
    private struct Action {
        let source: RemoteEndpoint
        let destination: RemoteEndpoint
        let sourceAttributes: RemoteAttributes
        let expectedDestination: RemoteAttributes?
        let link: String?
    }
    private let fs: any RemoteFileSystem
    private let scp: any ScpRunning
    private let chooseFile: (RemoteFileConflict) async -> RemoteFileConflictChoice
    private let choosePolicy: (String) async -> FolderTransferPolicy?
    private let skipConflict: (String) async -> Bool
    private let log: (String, RunResult) -> Void
    private let status: (String) -> Void
    private var actions: [Action] = []
    private var skipped = 0
    private let limitsOverride: ResourceLimits?
    private var traversalBudget = TraversalBudget()

    public init(fileSystem: any RemoteFileSystem, scp: any ScpRunning = ScpService(), limits: ResourceLimits? = nil,
                chooseFile: @escaping (RemoteFileConflict) async -> RemoteFileConflictChoice,
                choosePolicy: @escaping (String) async -> FolderTransferPolicy?,
                skipConflict: @escaping (String) async -> Bool,
                log: @escaping (String, RunResult) -> Void = { _, _ in },
                status: @escaping (String) -> Void = { _ in }) {
        fs = fileSystem; self.scp = scp; self.chooseFile = chooseFile; self.choosePolicy = choosePolicy
        self.skipConflict = skipConflict; self.log = log; self.status = status
        limitsOverride = limits?.validated
    }

    public static func availableCopyName(_ name: String, names: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        var n = 1
        while names.contains("\(stem)-\(n)\(suffix)") { n += 1 }
        return "\(stem)-\(n)\(suffix)"
    }

    public func run(source original: RemoteEndpoint, destinationDirectory: RemoteEndpoint,
                    expectedKind: RemoteAttributes.Kind? = nil) async throws -> FolderTransferSummary {
        actions = []; skipped = 0
        traversalBudget = TraversalBudget(limitsOverride ?? .standard)
        try original.validate(); try destinationDirectory.validate()
        guard original.path != "/" else { throw RemoteTransferError("ルートフォルダはコピーできません。") }
        try SFTPCommand.validateName(original.name)
        try Task.checkCancellation()
        status("走査中…")
        try await scp.checkAvailability()
        let sourceKey = try await scp.connectionKey(host: original.host)
        let destinationKey = try await scp.connectionKey(host: destinationDirectory.host)
        guard let originalAttributes = try await fs.attributes(original, followLink: false) else {
            throw RemoteTransferError("コピー元が存在しません: \(original.description)")
        }
        if let expectedKind, originalAttributes.kind != expectedKind { throw changed(original) }
        guard try await fs.attributes(destinationDirectory, followLink: false)?.kind == .directory else {
            throw RemoteTransferError("コピー先は通常のフォルダにしてください。")
        }
        let destinationParent = RemoteEndpoint(host: destinationDirectory.host, path: try await fs.realPath(destinationDirectory))
        var source = original
        var attributes = originalAttributes
        if attributes.kind == .symbolicLink,
           let followed = try await fs.attributes(original, followLink: true), followed.kind == .directory {
            source = RemoteEndpoint(host: original.host, path: try await fs.realPath(original))
            attributes = followed
        } else {
            source = RemoteEndpoint(host: original.host, path: try await fs.realPath(original.parent)).child(original.name)
        }
        if attributes.kind == .directory && source.path == "/" { throw RemoteTransferError("ルートフォルダはコピーできません。") }
        var destination = destinationParent.child(original.name)
        let current = try await fs.attributes(destination, followLink: false)
        let sameConnection = sourceKey == destinationKey
        if attributes.kind == .directory {
            if let current, current.kind != .directory {
                try await conflict(destination.description)
                return FolderTransferSummary(transferred: 0, skipped: skipped, directories: 0)
            }
            if sameConnection {
                let targetPath: String
                if current == nil { targetPath = destination.path }
                else { targetPath = try await fs.realPath(destination) }
                guard !Self.overlap(source.path, targetPath) else {
                    throw RemoteTransferError("同じフォルダ、または互いの配下へはコピーできません。")
                }
            }
            var policy = FolderTransferPolicy.overwrite
            if current != nil {
                guard let selected = await choosePolicy("\(source.description) → \(destination.description)") else { throw CancellationError() }
                policy = selected
            }
            try traversalBudget.consume(1)
            try await planFolder(source, destination, sourceAttributes: attributes, existing: current, policy: policy, depth: 0)
        } else if attributes.kind == .file || attributes.kind == .symbolicLink {
            if attributes.kind == .file && attributes.size == nil { throw RemoteTransferError("ファイルサイズを取得できません: \(source.description)") }
            if let current {
                var names = Set(try await fs.list(destinationParent).map(\.name))
                var alternative = Self.availableCopyName(original.name, names: names)
                // Probe the actual server namespace too: a differently cased
                // name may refer to the same file on a case-insensitive server.
                while try await fs.attributes(destinationParent.child(alternative), followLink: false) != nil {
                    names.insert(alternative)
                    alternative = Self.availableCopyName(original.name, names: names)
                }
                let canOverwrite = current.kind == attributes.kind && !(sameConnection && source.path == destination.path)
                switch await chooseFile(RemoteFileConflict(destination: destination, alternative: alternative, canOverwrite: canOverwrite)) {
                case .cancel: throw CancellationError()
                case .keepBoth: destination = destinationParent.child(alternative)
                case .overwrite:
                    guard canOverwrite else { throw RemoteTransferError("同じファイル、または種類の異なる項目には上書きできません。") }
                }
            }
            let link: String?
            if attributes.kind == .symbolicLink { link = try await fs.readLink(source) }
            else { link = nil }
            actions.append(Action(source: source, destination: destination, sourceAttributes: attributes,
                                  expectedDestination: destination == destinationParent.child(original.name) ? current : nil, link: link))
        } else { throw RemoteTransferError("特殊ファイルは転送対象外です。") }
        try Task.checkCancellation()
        let files = actions.filter { $0.sourceAttributes.kind != .directory }
        var completed = 0, directories = 0
        for action in actions {
            try Task.checkCancellation()
            try await checkParent(action.destination.parent)
            try await checkSource(action)
            if action.sourceAttributes.kind == .directory {
                if action.expectedDestination == nil {
                    try await checkDestination(action)
                    try await fs.createDirectory(action.destination)
                    directories += 1
                } else {
                    guard try await fs.attributes(action.destination, followLink: false)?.kind == .directory else {
                        throw changed(action.destination)
                    }
                }
            } else {
                status("転送中：\(completed)/\(files.count) · \(action.source.name)")
                try await publish(action)
                completed += 1
                status("転送中：\(completed)/\(files.count) · \(action.source.name)")
            }
        }
        status("保存を確定中…")
        for action in actions.reversed() where action.sourceAttributes.kind == .directory && action.expectedDestination == nil {
            try Task.checkCancellation()
            try await checkParent(action.destination.parent)
            guard try await fs.attributes(action.destination, followLink: false)?.kind == .directory else { throw changed(action.destination) }
            try await fs.setAttributes(action.destination, attributes: action.sourceAttributes)
        }
        return FolderTransferSummary(transferred: completed, skipped: skipped, directories: directories)
    }

    private func planFolder(_ source: RemoteEndpoint, _ destination: RemoteEndpoint,
                            sourceAttributes: RemoteAttributes, existing: RemoteAttributes?,
                            policy: FolderTransferPolicy, depth: Int) async throws {
        try traversalBudget.checkDepth(depth)
        try Task.checkCancellation()
        guard try await fs.attributes(source, followLink: false)?.kind == .directory,
              try await fs.realPath(source) == source.path else { throw changed(source) }
        let children = try await fs.list(source)
        guard children.count <= traversalBudget.limits.listingEntries else { throw ResourceLimitError.listing }
        try traversalBudget.consume(children.count)
        let targets: [RemoteNode]
        if existing == nil { targets = [] }
        else { targets = try await fs.list(destination) }
        guard targets.count <= traversalBudget.limits.listingEntries else { throw ResourceLimitError.listing }
        try traversalBudget.consume(targets.count)
        guard Set(children.map(\.name)).count == children.count, Set(targets.map(\.name)).count == targets.count else {
            throw RemoteTransferError("フォルダ一覧に重複した名前があります。")
        }
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0.attributes) })
        actions.append(Action(source: source, destination: destination, sourceAttributes: sourceAttributes, expectedDestination: existing, link: nil))
        for child in children.sorted(by: { $0.name < $1.name }) {
            try Task.checkCancellation()
            try SFTPCommand.validateName(child.name)
            let from = source.child(child.name), to = destination.child(child.name)
            let attrs = child.attributes, target = byName[child.name]
            guard attrs.kind != .other else { skipped += 1; continue }
            if attrs.kind == .file && attrs.size == nil { throw RemoteTransferError("ファイルサイズを取得できません: \(from.description)") }
            if let target, target.kind != attrs.kind { try await conflict(to.description); continue }
            if attrs.kind == .directory {
                try await planFolder(from, to, sourceAttributes: attrs, existing: target, policy: policy, depth: depth + 1)
            } else if attrs.kind == .symbolicLink {
                let link = try await fs.readLink(from)
                if policy == .updatedOnly, target != nil, try await fs.readLink(to) == link { skipped += 1 }
                else { actions.append(Action(source: from, destination: to, sourceAttributes: attrs, expectedDestination: target, link: link)) }
            } else if Self.needsTransfer(attrs, target, policy: policy) {
                actions.append(Action(source: from, destination: to, sourceAttributes: attrs, expectedDestination: target, link: nil))
            } else { skipped += 1 }
        }
    }

    public static func needsTransfer(_ source: RemoteAttributes, _ target: RemoteAttributes?, policy: FolderTransferPolicy) -> Bool {
        guard let target else { return true }
        if source.size == nil || target.size == nil { return true }
        if policy == .overwrite || source.size != target.size { return true }
        guard let a = source.modified, let b = target.modified else { return true }
        return a > b
    }
    private func publish(_ action: Action) async throws {
        try await checkDestination(action)
        let temporary = action.destination.parent.child(".opensftp-\(UUID().uuidString).partial")
        // Record the path before creation, including when the transfer is killed.
        diagnostic("一時項目: \(temporary.description)\n")
        var created = false
        do {
            if let link = action.link {
                try await fs.createLink(temporary, target: link)
                created = true
            } else {
                try await fs.createFile(temporary)
                created = true
                let request = try ScpRequest(source: action.source, destination: temporary)
                let result = await scp.run(request)
                log(action.destination.host, RunResult(started: result.started, ended: result.ended,
                    stdout: "$ \(request.commandLine)\n\(result.stdout)", stderr: result.stderr,
                    exitCode: result.exitCode, failure: result.failure))
                try Task.checkCancellation()
                guard result.succeeded else { throw RemoteTransferError("scpによる転送に失敗しました。詳細ログを確認してください。") }
                guard let saved = try await fs.attributes(temporary, followLink: false), saved.kind == .file,
                      let size = action.sourceAttributes.size, saved.size == size else { throw changed(temporary) }
                try await fs.setAttributes(temporary, attributes: action.sourceAttributes)
            }
            try Task.checkCancellation()
            try await checkSource(action)
            try await checkParent(action.destination.parent)
            try await checkDestination(action)
            status("保存を確定中…")
            try await fs.rename(temporary, to: action.destination, overwrite: action.expectedDestination != nil)
        } catch {
            guard created else { throw error }
            let fs = self.fs
            // Cleanup must work even after the job's Task has been cancelled.
            do { try await Task { try await fs.remove(temporary) }.value }
            catch { diagnostic("一時項目が残っている可能性があります: \(temporary.description)\n\(error.localizedDescription)\n") }
            throw error
        }
    }
    private func checkSource(_ action: Action) async throws {
        guard let current = try await fs.attributes(action.source, followLink: false),
              Self.unchanged(current, action.sourceAttributes) else { throw changed(action.source) }
        if let link = action.link, try await fs.readLink(action.source) != link { throw changed(action.source) }
        try await checkParent(action.source.parent)
    }
    private func checkDestination(_ action: Action) async throws {
        let current = try await fs.attributes(action.destination, followLink: false)
        switch (current, action.expectedDestination) {
        case (nil, nil): return
        case let (current?, expected?) where Self.unchanged(current, expected): return
        default: throw changed(action.destination)
        }
    }
    private func checkParent(_ parent: RemoteEndpoint) async throws {
        guard try await fs.attributes(parent, followLink: false)?.kind == .directory,
              try await fs.realPath(parent) == parent.path else { throw changed(parent) }
    }
    private static func unchanged(_ a: RemoteAttributes, _ b: RemoteAttributes) -> Bool {
        a.kind == b.kind && a.permissions == b.permissions && a.size == b.size && a.modified == b.modified
    }
    public static func overlap(_ a: String, _ b: String) -> Bool {
        a == "/" || b == "/" || a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    private func conflict(_ message: String) async throws {
        guard await skipConflict(message) else { throw CancellationError() }
        try Task.checkCancellation()
        skipped += 1
    }
    private func changed(_ e: RemoteEndpoint) -> RemoteTransferError {
        RemoteTransferError("転送計画後に項目が変更されました: \(e.description)")
    }
    private func diagnostic(_ message: String) {
        log("", RunResult(started: Date(), ended: Date(), stdout: message, stderr: "", exitCode: 0, failure: nil))
    }
}
