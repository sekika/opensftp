import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum FolderTransferPolicy: Sendable, Equatable { case overwrite, updatedOnly }
public enum FolderTransferDirection: Sendable, Equatable { case upload, download }

public struct FolderTransferSummary {
    /// Native rsync statistics do not report every planner count; omit unknowns.
    public let transferred: Int?
    public let skipped: Int?
    public let directories: Int?
    public let deleted: Int?
    public init(transferred: Int? = nil, skipped: Int? = nil, directories: Int? = nil, deleted: Int? = nil) {
        self.transferred = transferred; self.skipped = skipped; self.directories = directories; self.deleted = deleted
    }
    public var description: String {
        var counts: [String] = []
        if let transferred { counts.append("転送\(transferred)件") }
        if let skipped { counts.append("スキップ\(skipped)件") }
        if let directories { counts.append("フォルダ作成\(directories)件") }
        if let deleted { counts.append("削除\(deleted)件") }
        return counts.isEmpty ? "完了（詳細はログを確認）" : "完了：" + counts.joined(separator: "・")
    }

    static func rsyncStatistics(_ output: String) -> FolderTransferSummary {
        func count(_ label: String) -> Int? {
            guard let range = output.range(of: "(?m)^" + label + #":\s*([0-9,]+)"#, options: .regularExpression) else { return nil }
            let number = output[range].split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)
            return Int(number.replacingOccurrences(of: ",", with: ""))
        }
        return FolderTransferSummary(transferred: count("Number of (?:regular )?files transferred"),
                                     deleted: count("Number of deleted files"))
    }
}

/// Plans a merge without deletions, preserving descendant symbolic links.
/// Each instance belongs to one queue job. UI decisions and local file commits
/// stay on the main actor; SFTPRunning performs process I/O off that actor.
@MainActor
public final class FolderTransfer {
    private struct Item {
        let kind: RemoteEntry.Kind
        let size: Int64
        let date: Date?
        let minutePrecision: Bool
    }
    private struct Action {
        let local: URL
        let remote: String
        let directory: Bool
        let size: Int64
        var linkTarget: String? = nil
        var kind: RemoteEntry.Kind { directory ? .directory : linkTarget == nil ? .file : .symbolicLink }
    }
    private let host: String
    private let service: any SFTPRunning
    private let rsync: any RsyncRunning
    private let fileSystem: any RemoteFileSystem
    private var uploadGuard: RemoteUpload?
    private let limitsOverride: ResourceLimits?
    private var traversalBudget = TraversalBudget()
    private let chooseMethod: ((Bool) -> FolderTransferMethod?)?
    private let choosePolicy: (String) -> FolderTransferPolicy?
    private let skipConflict: (String) -> Bool
    private let preferences: ConnectionPreferences
    private let log: (RunResult) -> Void
    private let status: (String) -> Void
    private let rsyncOutput: ((String, String) -> Void)?
    private var rsyncStdout = "", rsyncStderr = ""
    private var actions: [Action] = []
    private var skipped = 0

    public init(host: String, service: any SFTPRunning, rsync: any RsyncRunning = RsyncService(),
                fileSystem: any RemoteFileSystem = SFTPRemoteFileSystem(),
                limits: ResourceLimits? = nil,
                preferences: ConnectionPreferences = .standard,
                chooseMethod: ((Bool) -> FolderTransferMethod?)? = nil,
                choosePolicy: @escaping (String) -> FolderTransferPolicy?,
                skipConflict: @escaping (String) -> Bool,
                log: @escaping (RunResult) -> Void,
                status: @escaping (String) -> Void,
                rsyncOutput: ((String, String) -> Void)? = nil) {
        self.chooseMethod = chooseMethod
        self.host = host; self.service = service; self.rsync = rsync; self.preferences = preferences
        self.fileSystem = fileSystem
        self.limitsOverride = limits?.validated
        self.choosePolicy = choosePolicy
        self.skipConflict = skipConflict; self.log = log; self.status = status
        self.rsyncOutput = rsyncOutput
    }

    public static func needsTransfer(policy: FolderTransferPolicy, sourceSize: Int64, sourceDate: Date?,
                                     destinationSize: Int64, destinationDate: Date?, compareByDay: Bool = false,
                                     calendar: Calendar = .current) -> Bool {
        if policy == .overwrite || sourceSize != destinationSize { return true }
        guard let sourceDate, let destinationDate else { return true }
        // Older ls timestamps omit the time. Compare both sides at that same
        // calendar-day precision rather than retransferring every old file.
        if compareByDay {
            return calendar.startOfDay(for: sourceDate) > calendar.startOfDay(for: destinationDate)
        }
        // OpenSSH ls reports recent timestamps only to the minute.
        return floor(sourceDate.timeIntervalSince1970 / 60) > floor(destinationDate.timeIntervalSince1970 / 60)
    }

    /// Copies an individually selected file/dangling link. Selected directory
    /// links are sent through run() by the caller to follow that source root.
    public func runLink(local: URL, remote: String, direction: FolderTransferDirection) async throws {
        try SFTPCommand.validateHost(host)
        try SFTPCommand.validatePath(remote)
        uploadGuard = nil
        var remote = remote
        if direction == .upload {
            remote = try await prepareUpload(remote)
        }
        let parent = (remote as NSString).deletingLastPathComponent
        let current = (try await list(parent)).first { $0.name == (remote as NSString).lastPathComponent }
        let target: String
        switch direction {
        case .upload:
            guard try localItem(local)?.kind == .symbolicLink else { throw failure("転送元はリンクではありません。") }
            target = try FileManager.default.destinationOfSymbolicLink(atPath: local.path)
        case .download:
            guard current?.kind == .symbolicLink else { throw failure("転送元はリンクではありません。") }
            guard try localItem(local) == nil else { throw failure("保存先に同名の項目が存在します。") }
            target = try await readLink(remote)
        }
        try SFTPCommand.validatePath(target)
        try Task.checkCancellation()
        try await copyLink(Action(local: local, remote: remote, directory: false, size: 0, linkTarget: target), direction: direction)
    }

    public func run(local: URL, remote: String, direction: FolderTransferDirection, method methodArgument: FolderTransferMethod = .sftp,
                    progress: @escaping @Sendable (TransferProgress) async -> Void) async throws -> FolderTransferSummary {
        try Task.checkCancellation()
        actions = []; skipped = 0; uploadGuard = nil
        traversalBudget = TraversalBudget(limitsOverride ?? .standard)
        try SFTPCommand.validateHost(host)
        try SFTPCommand.validatePath(remote)
        guard remote.hasPrefix("/"), remote != "/" else { throw failure("転送先・転送元には名前のあるフォルダを指定してください。") }
        status("フォルダを確認中…")
        // Only an explicitly selected source folder link is followed. Descendant
        // links are planned as links and are never used as traversal roots.
        let local = direction == .upload ? local.resolvingSymlinksInPath() : local
        var remote = remote
        var parent = (remote as NSString).deletingLastPathComponent
        var remoteRoot = (try await list(parent)).first { $0.name == (remote as NSString).lastPathComponent }
        if direction == .download {
            if remoteRoot?.kind == .symbolicLink {
                let result = try await command(SFTPCommand.listing(remote))
                let listing = try DirectoryListing.parseChecked(result.stdout, limits: traversalBudget.limits)
                guard let resolved = listing.path, listing.unparsed.isEmpty else { throw failure("リンク先フォルダを取得できません: \(remote)") }
                remote = resolved
                parent = (remote as NSString).deletingLastPathComponent
                remoteRoot = (try await list(parent)).first { $0.name == (remote as NSString).lastPathComponent }
            }
        }
        let name = (remote as NSString).lastPathComponent
        try SFTPCommand.validateName(name)
        let localRoot = try localItem(local)
        let destination: Item?
        switch direction {
        case .upload:
            guard localRoot?.kind == .directory else { throw failure("アップロード元は通常のフォルダにしてください。") }
            destination = remoteRoot.map(item)
        case .download:
            guard remoteRoot?.isDirectory == true else { throw failure("ダウンロード元は通常のフォルダにしてください。") }
            destination = localRoot
        }
        if let destination, destination.kind != .directory {
            try conflict("\(local.path) ↔ \(host):\(remote)\nフォルダと異なる種類の項目が存在します。")
            return FolderTransferSummary(transferred: 0, skipped: skipped, directories: 0)
        }
        let method: FolderTransferMethod
        if let chooseMethod {
            guard let selected = chooseMethod(destination != nil) else { throw CancellationError() }
            method = selected
        } else { method = methodArgument }
        if direction == .upload, method == .sftp || method == .sftpOverwrite {
            remote = try await prepareUpload(remote)
            parent = (remote as NSString).deletingLastPathComponent
        }
        try Task.checkCancellation()
        if method == .rsync || method == .rsyncDelete {
            let deleteExtraneous = (method == .rsyncDelete)
            let request = try RsyncRequest(host: host, local: local, remote: remote, direction: direction,
                                           files: [], deleteExtraneous: deleteExtraneous, preferences: preferences)
            // --rsync-path starts in this root. Create only the root if absent;
            // rsync handles the complete subtree, including an empty source.
            if destination == nil {
                switch direction {
                case .upload: _ = try await command(SFTPCommand.operation("mkdir", remote))
                case .download: try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
                }
            }
            if direction == .download {
                guard try localItem(local)?.kind == .directory else { throw failure("保存先フォルダの種類が変更されました。") }
            } else {
                guard (try await list(parent)).first(where: { $0.name == name })?.isDirectory == true else {
                    throw failure("転送先フォルダの種類が変更されました。")
                }
            }
            let message = deleteExtraneous ? "rsync --delete 転送中…" : "rsync 転送中…"
            let result = try await executeRsync(request, message: message)
            return FolderTransferSummary.rsyncStatistics(result.stdout)
        }
        let policy: FolderTransferPolicy
        if destination != nil {
            guard let selected = choosePolicy("\(local.path) ↔ \(host):\(remote)") else { throw CancellationError() }
            policy = selected
        } else { policy = .overwrite }
        switch direction {
        case .upload:
            try traversalBudget.consume(1)
            try await planUpload(local, remote, existing: destination, policy: policy, depth: 0)
        case .download:
            try traversalBudget.consume(1)
            try await planDownload(local, remote, existing: destination, policy: policy, depth: 0)
        }
        let files = actions.filter { !$0.directory }
        let totalBytes = files.reduce(Double(0)) { $0 + Double($1.size) }
        let started = Date()
        var completed = 0, directories = 0
        var completedBytes: Double = 0
        for action in actions {
            try Task.checkCancellation()
            status("\(completed)/\(files.count)件 · \((action.remote as NSString).lastPathComponent)")
            try checkLocalParents(of: action.local, root: local)
            if action.directory {
                switch direction {
                case .upload:
                    guard let uploadGuard else { throw failure("転送先を確認できません。") }
                    let destination = RemoteEndpoint(host: host, path: action.remote)
                    try await uploadGuard.checkParents(of: destination)
                    try await fileSystem.createDirectory(destination)
                case .download:
                    guard try localItem(action.local) == nil else { throw failure("保存先が転送計画後に変更されました: \(action.local.path)") }
                    try FileManager.default.createDirectory(at: action.local, withIntermediateDirectories: false)
                }
                directories += 1
                continue
            }
            if action.linkTarget != nil {
                try await copyLink(action, direction: direction)
                completed += 1
                continue
            }
            let base = completedBytes
            let size = Double(action.size)
            let onProgress: @Sendable (TransferProgress) async -> Void = { value in
                await progress(Self.overallProgress(bytes: base + size * value.fraction, total: totalBytes,
                                                    speed: value.speed, started: started))
            }
            switch direction {
            case .upload:
                guard try localItem(action.local)?.kind == .file else { throw failure("転送元の種類が変更されました: \(action.local.path)") }
                guard let uploadGuard else { throw failure("転送先を確認できません。") }
                try await uploadGuard.upload(to: RemoteEndpoint(host: host, path: action.remote), preserveSourceAttributes: true) { temporary in
                    _ = try await self.command(SFTPCommand.transfer("put", action.local.path, temporary.path), progress: onProgress)
                }
            case .download:
                try await downloadFile(action, progress: onProgress)
            }
            completed += 1
            completedBytes += size
            await progress(Self.overallProgress(bytes: completedBytes, total: totalBytes, speed: "—", started: started))
        }
        return FolderTransferSummary(transferred: completed, skipped: skipped, directories: directories)
    }

    private func receiveRsyncOutput(_ chunk: RsyncOutputChunk) {
        guard let rsyncOutput else { return }
        switch chunk {
        case let .stdout(text): rsyncStdout = BoundedLog.clip(rsyncStdout + text)
        case let .stderr(text): rsyncStderr = BoundedLog.clip(rsyncStderr + text)
        }
        rsyncOutput(rsyncStdout, rsyncStderr)
    }

    private func prepareUpload(_ remote: String) async throws -> String {
        let upload = try await RemoteUpload.prepare(
            directory: RemoteEndpoint(host: host, path: (remote as NSString).deletingLastPathComponent),
            fileSystem: fileSystem, diagnostic: { [weak self] message in
                let now = Date()
                self?.log(RunResult(started: now, ended: now, stdout: "", stderr: message, exitCode: 0, failure: nil))
            })
        uploadGuard = upload
        return try upload.destination(named: (remote as NSString).lastPathComponent).path
    }

    private func executeRsync(_ request: RsyncRequest, message: String) async throws -> RunResult {
        try Task.checkCancellation()
        status(message)
        let now = Date()
        log(RunResult(started: now, ended: now, stdout: "\n$ \(request.commandLine)\n", stderr: "", exitCode: 0, failure: nil))
        rsyncStdout = ""; rsyncStderr = ""
        let result = await rsync.run(request) { chunk in await self.receiveRsyncOutput(chunk) }
        if let rsyncOutput {
            rsyncOutput(result.stdout, result.stderr)
            log(RunResult(started: result.started, ended: result.ended, stdout: "", stderr: "", exitCode: result.exitCode, failure: result.failure))
        } else { log(result) }
        try Task.checkCancellation()
        if result.failure == .launch { throw failure("rsyncを起動できません。ローカルの /usr/bin/rsync を確認してください。") }
        guard result.succeeded else {
            throw failure("rsync転送に失敗しました（終了コード: \(result.exitCode)）。接続先でrsyncとSSHのコマンド実行が使えることを確認してください。詳細はログに記録しています。")
        }
        return result
    }

    private func planUpload(_ local: URL, _ remote: String, existing: Item?, policy: FolderTransferPolicy, depth: Int) async throws {
        try checkDepth(depth)
        status("フォルダを確認中：\(remote)")
        let destination: [String: RemoteEntry]
        if existing == nil { destination = [:] }
        else {
            let existing = try await list(remote)
            try traversalBudget.consume(existing.count)
            destination = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })
        }
        if existing == nil { actions.append(Action(local: local, remote: remote, directory: true, size: 0)) }
        // URL enumeration may return /private/var children even when the
        // selected/resolved root uses /var. Build every action from the same
        // root spelling instead of mixing those equivalent filesystem paths.
        let names = try localNames(local)
        try traversalBudget.consume(names.count)
        for name in names {
            await Task.yield()
            try Task.checkCancellation()
            try SFTPCommand.validateName(name)
            let child = local.appendingPathComponent(name)
            guard let source = try localItem(child) else { throw failure("転送元が見つかりません: \(child.path)") }
            let targetPath = SFTPCommand.join(remote, child.lastPathComponent)
            let target = destination[child.lastPathComponent].map(item)
            guard source.kind == .file || source.kind == .directory || source.kind == .symbolicLink else { skipped += 1; continue }
            if let target, target.kind != source.kind { try conflict("\(child.path) ↔ \(host):\(targetPath)\n種類が異なる項目、またはリンクが存在します。"); continue }
            if source.kind == .directory {
                try await planUpload(child, targetPath, existing: target, policy: policy, depth: depth + 1)
            } else if source.kind == .symbolicLink {
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                try SFTPCommand.validatePath(link)
                if policy == .updatedOnly, target != nil, try await readLink(targetPath) == link { skipped += 1 }
                else { actions.append(Action(local: child, remote: targetPath, directory: false, size: 0, linkTarget: link)) }
            } else if shouldTransfer(source, target, policy) {
                actions.append(Action(local: child, remote: targetPath, directory: false, size: source.size))
            } else { skipped += 1 }
        }
    }

    private func planDownload(_ local: URL, _ remote: String, existing: Item?, policy: FolderTransferPolicy, depth: Int) async throws {
        try checkDepth(depth)
        status("フォルダを確認中：\(remote)")
        let source = try await list(remote)
        try traversalBudget.consume(source.count)
        if existing == nil { actions.append(Action(local: local, remote: remote, directory: true, size: 0)) }
        for child in source.sorted(by: { $0.name < $1.name }) {
            await Task.yield()
            try Task.checkCancellation()
            let childLocal = local.appendingPathComponent(child.name)
            let childRemote = SFTPCommand.join(remote, child.name)
            let target = try localItem(childLocal)
            guard child.isRegularFile || child.isDirectory || child.kind == .symbolicLink else { skipped += 1; continue }
            if let target, target.kind != child.kind { try conflict("\(childLocal.path) ↔ \(host):\(childRemote)\n種類が異なる項目、またはリンクが存在します。"); continue }
            if child.isDirectory {
                try await planDownload(childLocal, childRemote, existing: target, policy: policy, depth: depth + 1)
            } else if child.kind == .symbolicLink {
                let link = try await readLink(childRemote)
                if policy == .updatedOnly, target != nil,
                   try FileManager.default.destinationOfSymbolicLink(atPath: childLocal.path) == link { skipped += 1 }
                else { actions.append(Action(local: childLocal, remote: childRemote, directory: false, size: 0, linkTarget: link)) }
            } else if shouldTransfer(item(child), target, policy) {
                actions.append(Action(local: childLocal, remote: childRemote, directory: false, size: child.size))
            } else { skipped += 1 }
        }
    }

    private func localNames(_ directory: URL) throws -> [String] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw failure("フォルダ一覧を完全に解析できません: \(directory.path)") }
        var names: [String] = [], bytes = 0
        for case let child as URL in enumerator {
            let name = child.lastPathComponent
            let size = name.utf8.count + 1
            guard names.count < traversalBudget.limits.listingEntries,
                  size <= traversalBudget.limits.listingBytes - bytes else { throw ResourceLimitError.listing }
            bytes += size
            names.append(name)
        }
        if let enumerationError { throw enumerationError }
        return names.sorted()
    }

    private func downloadFile(_ action: Action, progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        let fm = FileManager.default
        let destination = try localItem(action.local)
        guard destination == nil || destination?.kind == .file else { throw failure("保存先の種類が変更されました: \(action.local.path)") }
        let temporary = action.local.deletingLastPathComponent().appendingPathComponent(".opensftp-\(UUID().uuidString).partial")
        guard fm.createFile(atPath: temporary.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw failure("一時ファイルを作成できません: \(temporary.path)") }
        defer { try? fm.removeItem(at: temporary) }
        _ = try await command(SFTPCommand.transfer("get", action.remote, temporary.path), progress: progress)
        let current = try localItem(action.local)
        guard current == nil || current?.kind == .file else { throw failure("保存先の種類が変更されました: \(action.local.path)") }
        if current != nil {
            // get -p supplies remote permissions and timestamps for new files.
            // On overwrite, keep the existing local permission bits instead:
            // publishing the remote mode could broaden access to private data.
            // Change only the staged file's mode so its remote timestamp survives
            // replaceItemAt(.usingNewMetadataOnly) along with the new contents.
            let attributes = try fm.attributesOfItem(atPath: action.local.path)
            guard let permissions = attributes[.posixPermissions] else {
                throw failure("保存先のアクセス権を取得できません: \(action.local.path)")
            }
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            _ = try fm.replaceItemAt(action.local, withItemAt: temporary, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else { try fm.moveItem(at: temporary, to: action.local) }
    }

    private func readLink(_ path: String) async throws -> String {
        try Task.checkCancellation()
        let result = await service.readLink(host: host, path: path)
        log(RunResult(started: result.started, ended: result.ended,
                      stdout: "sftp readlink \(try SFTPCommand.quote(path))\n\(result.stdout)\n",
                      stderr: result.stderr, exitCode: result.exitCode, failure: result.failure))
        try Task.checkCancellation()
        guard result.succeeded else { throw failure("リンク先を取得できません: \(path)。詳細ログを確認してください。") }
        try SFTPCommand.validatePath(result.stdout)
        return result.stdout
    }

    private func copyLink(_ action: Action, direction: FolderTransferDirection) async throws {
        guard let target = action.linkTarget else { return }
        switch direction {
        case .upload:
            guard try localItem(action.local)?.kind == .symbolicLink,
                  try FileManager.default.destinationOfSymbolicLink(atPath: action.local.path) == target else {
                throw failure("転送元のリンクが変更されました: \(action.local.path)")
            }
            let parent = (action.remote as NSString).deletingLastPathComponent
            guard let uploadGuard else { throw failure("転送先を確認できません。") }
            try await uploadGuard.checkParents(of: RemoteEndpoint(host: host, path: action.remote))
            let current = (try await list(parent)).first { $0.name == (action.remote as NSString).lastPathComponent }
            guard current == nil || current?.kind == .symbolicLink else { throw failure("転送先の種類が変更されました: \(action.remote)") }
            let temporary = SFTPCommand.join(parent, ".opensftp-\(UUID().uuidString).partial")
            _ = try await command(SFTPCommand.symbolicLink(target: target, path: temporary))
            do {
                try await uploadGuard.checkParents(of: RemoteEndpoint(host: host, path: action.remote))
                let latest = (try await list(parent)).first { $0.name == (action.remote as NSString).lastPathComponent }
                guard latest == nil || latest?.kind == .symbolicLink else { throw failure("転送先の種類が変更されました: \(action.remote)") }
                // OpenSSH uses posix-rename when available. A server without
                // overwrite support fails while preserving the existing link.
                _ = try await command(SFTPCommand.operation("rename", temporary, action.remote))
            } catch {
                // Do not follow a changed parent during best-effort cleanup.
                try? await Task { @MainActor in
                    try await uploadGuard.checkParents(of: RemoteEndpoint(host: self.host, path: temporary))
                    _ = await self.service.run(host: self.host, commands: try SFTPCommand.operation("rm", temporary))
                }.value
                throw error
            }
        case .download:
            let current = try localItem(action.local)
            guard current == nil || current?.kind == .symbolicLink else { throw failure("保存先の種類が変更されました: \(action.local.path)") }
            let temporary = action.local.deletingLastPathComponent().appendingPathComponent(".opensftp-\(UUID().uuidString).partial")
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let latest = try localItem(action.local)
            guard latest == nil || latest?.kind == .symbolicLink else { throw failure("保存先の種類が変更されました: \(action.local.path)") }
            // rename(2) works for dangling links too and atomically replaces a
            // destination link without opening either link's target.
            guard rename(temporary.path, action.local.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    private func list(_ remote: String) async throws -> [RemoteEntry] {
        let result = try await command(SFTPCommand.listing(remote))
        let listing = try DirectoryListing.parseChecked(result.stdout, limits: traversalBudget.limits)
        guard listing.path != nil, listing.unparsed.isEmpty else { throw failure("フォルダ一覧を完全に解析できません: \(remote)") }
        if listing.entries.contains(where: { $0.kind == .symbolicLink }) {
            let exact = try await command(["cd " + SFTPCommand.quote(remote), "ls -1a", "bye"])
            var names: [String] = []
            for line in LFLineSequence(exact.stdout) {
                if line.isEmpty || line.hasPrefix("sftp> ") || line == "." || line == ".." { continue }
                guard names.count < traversalBudget.limits.listingEntries else { throw ResourceLimitError.listing }
                names.append(line)
            }
            guard names.count == Set(names).count, Set(names) == Set(listing.entries.map(\.name)) else {
                throw failure("リンクの名前が曖昧か、フォルダが変更されています: \(remote)")
            }
        }
        return listing.entries
    }
    private func command(_ commands: [String], progress: @escaping @Sendable (TransferProgress) async -> Void = { _ in }) async throws -> RunResult {
        try Task.checkCancellation()
        let result = await service.run(host: host, commands: commands, progress: progress)
        log(result)
        try Task.checkCancellation()
        if let failure = result.failure { throw self.failure("\(failure.rawValue)。フォルダ転送は一部のみ完了している可能性があります。詳細ログを確認してください。") }
        return result
    }
    private func item(_ entry: RemoteEntry) -> Item {
        Item(kind: entry.kind, size: entry.size, date: entry.modifiedDate, minutePrecision: entry.modified.contains(":"))
    }
    private func localItem(_ url: URL) throws -> Item? {
        do {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = values[.type] as? FileAttributeType
            let kind: RemoteEntry.Kind = type == .typeDirectory ? .directory : type == .typeRegular ? .file : type == .typeSymbolicLink ? .symbolicLink : .other
            return Item(kind: kind, size: (values[.size] as? NSNumber)?.int64Value ?? 0,
                        date: values[.modificationDate] as? Date, minutePrecision: true)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return nil }
            throw error
        }
    }
    private func shouldTransfer(_ source: Item, _ target: Item?, _ policy: FolderTransferPolicy) -> Bool {
        guard let target else { return true }
        return Self.needsTransfer(policy: policy, sourceSize: source.size, sourceDate: source.date,
                                  destinationSize: target.size, destinationDate: target.date,
                                  compareByDay: !source.minutePrecision || !target.minutePrecision)
    }
    private func conflict(_ message: String) throws {
        guard skipConflict(message) else { throw failure("種類の衝突によりフォルダ転送を中止しました。") }
        skipped += 1
    }
    private func checkDepth(_ depth: Int) throws {
        try traversalBudget.checkDepth(depth)
    }
    private func checkLocalParents(of url: URL, root: URL) throws {
        // Reject directory-to-symlink substitutions discovered after planning.
        // The user-selected parent of the root remains outside this traversal.
        // Keep the paths used by the planner. Standardizing a URL that ends in
        // a symlink can change its path (including macOS /var aliases) before
        // we remove the leaf, so it no longer shares the root's boundary.
        // Inspect ancestors only; the leaf is allowed to be a preserved link.
        let boundary = root.deletingLastPathComponent()
        var parent = url.deletingLastPathComponent()
        guard url.pathComponents.starts(with: root.pathComponents) else {
            throw failure("転送対象がフォルダの範囲外です: \(url.path)")
        }
        while parent.pathComponents != boundary.pathComponents {
            guard parent.pathComponents.count > boundary.pathComponents.count,
                  try localItem(parent)?.kind == .directory else {
                throw failure("転送中にフォルダの種類が変更されました: \(parent.path)")
            }
            parent = parent.deletingLastPathComponent()
        }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "OpenSFTP.FolderTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    nonisolated private static func overallProgress(bytes: Double, total: Double, speed: String, started: Date) -> TransferProgress {
        let elapsed = Date().timeIntervalSince(started)
        let remaining: String
        if bytes >= total { remaining = "—" }
        else if elapsed >= 1, bytes > 0 {
            let seconds = Int(min(359999, max(0, (total - bytes) / (bytes / elapsed))))
            remaining = String(format: "約%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        } else { remaining = "計算中" }
        return TransferProgress(fraction: total > 0 ? min(1, bytes / total) : 1,
                                transferred: ByteCountFormatter.string(fromByteCount: Int64(min(bytes, Double(Int64.max - 1024))), countStyle: .file),
                                speed: speed, remaining: remaining)
    }
}
