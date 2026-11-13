import XCTest
import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import SFTPCore
@testable import OpenSFTP

private actor StubRunner: SFTPRunning, RemoteFileSystem {
    let failDownloads: Bool
    let resolvedPaths: [String: String]
    var active = 0
    var maximumActive = 0
    var batches: [[String]] = []
    var uploadFiles: Set<String> = ["/home/test/visible.txt"]
    var publishedUploads: [String] = []
    func attributes(_ e: RemoteEndpoint, followLink: Bool) async throws -> RemoteAttributes? {
        if ["/", "/home", "/home/test"].contains(e.path) { return RemoteAttributes(permissions: 0o040755) }
        return uploadFiles.contains(e.path) ? RemoteAttributes(size: 1, permissions: 0o100644) : nil
    }
    func list(_ e: RemoteEndpoint) async throws -> [RemoteNode] { [] }
    func realPath(_ e: RemoteEndpoint) async throws -> String { resolvedPaths[e.path] ?? e.path }
    func readLink(_ e: RemoteEndpoint) async throws -> String { throw RemoteTransferError("not a link") }
    func createDirectory(_ e: RemoteEndpoint) async throws { throw RemoteTransferError("unexpected mkdir") }
    func createFile(_ e: RemoteEndpoint) async throws {
        guard uploadFiles.insert(e.path).inserted else { throw RemoteTransferError("exists") }
    }
    func setAttributes(_ e: RemoteEndpoint, attributes: RemoteAttributes) async throws {}
    func createLink(_ e: RemoteEndpoint, target: String) async throws { throw RemoteTransferError("unexpected link") }
    func rename(_ e: RemoteEndpoint, to destination: RemoteEndpoint, overwrite: Bool) async throws {
        guard uploadFiles.contains(e.path), overwrite || !uploadFiles.contains(destination.path) else { throw RemoteTransferError("exists") }
        uploadFiles.remove(e.path); uploadFiles.insert(destination.path)
        publishedUploads.append(destination.path)
    }
    func remove(_ e: RemoteEndpoint) async throws { uploadFiles.remove(e.path) }
    init(failDownloads: Bool = true, resolvedPaths: [String: String] = [:]) {
        self.failDownloads = failDownloads; self.resolvedPaths = resolvedPaths
    }
    func run(host: String, commands: [String]) async -> RunResult {
        active += 1
        maximumActive = max(maximumActive, active)
        batches.append(commands)
        try? await Task.sleep(nanoseconds: 5_000_000)
        active -= 1
        let now = Date()
        if failDownloads, commands.first?.hasPrefix("get ") == true {
            return RunResult(started: now, ended: now, stdout: "", stderr: "Connection reset", exitCode: 255, failure: .network)
        }
        return RunResult(started: now, ended: now, stdout: """
        Remote working directory: /home/test
        -rw-r--r-- ? u g 1 Jan 1 2024 visible.txt
        -rw-r--r-- ? u g 1 Jan 1 2024 .hidden
        drwxr-xr-x ? u g 2 Jan 1 2024 folder
        """, stderr: "", exitCode: 0, failure: nil)
    }
}

private actor ProgressRunner: SFTPRunning {
    private var completion: CheckedContinuation<Void, Never>?
    private let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func run(host: String, commands: [String]) async -> RunResult {
        let now = Date()
        return RunResult(started: now, ended: now, stdout: "", stderr: "", exitCode: fail ? 255 : 0, failure: fail ? .network : nil)
    }
    func run(host: String, commands: [String], progress: @escaping @Sendable (TransferProgress) async -> Void) async -> RunResult {
        await progress(TransferProgress.parse("file 0% 0 0.0KB/s --:-- ETA")!)
        await withCheckedContinuation { completion = $0 }
        return await run(host: host, commands: commands)
    }
    func finish() { completion?.resume(); completion = nil }
    var ready: Bool { completion != nil }
}

private actor AppRsyncRunner: RsyncRunning {
    var requests: [RsyncRequest] = []
    func run(_ request: RsyncRequest) async -> RunResult {
        requests.append(request)
        return RunResult(started: Date(), ended: Date(), stdout: "rsync statistics", stderr: "", exitCode: 0, failure: nil)
    }
}

private actor StreamingAppRsyncRunner: RsyncRunning {
    let fail: Bool
    var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(fail: Bool) { self.fail = fail }
    var ready: Bool { continuation != nil }
    func finish() { released = true; continuation?.resume(); continuation = nil }
    func run(_ request: RsyncRequest) async -> RunResult { await run(request, output: { _ in }) }
    func run(_ request: RsyncRequest, output: @escaping @Sendable (RsyncOutputChunk) async -> Void) async -> RunResult {
        let started = Date()
        await output(.stdout("first.txt\n"))
        await output(.stderr("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        await output(.stderr("c2VjcmV0\n"))
        if !released { await withCheckedContinuation { continuation = $0 } }
        await output(.stdout("finished\n"))
        await output(.stderr("-----END OPENSSH PRIVATE KEY-----\n"))
        return RunResult(started: started, ended: Date(), stdout: "first.txt\nfinished\n",
                         stderr: "-----BEGIN OPENSSH PRIVATE KEY-----\nc2VjcmV0\n-----END OPENSSH PRIVATE KEY-----\n",
                         exitCode: fail ? 23 : 0, failure: fail ? .operation : nil)
    }
}

private actor LinkRunner: SFTPRunning {
    let failNavigation: Bool
    let fileTarget: Bool
    let unknownTarget: Bool
    var batches: [[String]] = []
    init(failNavigation: Bool, fileTarget: Bool = false, unknownTarget: Bool = false) {
        self.failNavigation = failNavigation; self.fileTarget = fileTarget; self.unknownTarget = unknownTarget
    }
    func directoryLinks(host: String, paths: [String]) async -> [String: Bool] {
        unknownTarget ? [:] : Dictionary(uniqueKeysWithValues: paths.map { ($0, !fileTarget) })
    }
    func run(host: String, commands: [String]) async -> RunResult {
        batches.append(commands)
        if fileTarget, commands.first?.hasPrefix("get ") == true {
            let now = Date()
            do {
                let values = commands[0].components(separatedBy: "\"")
                try Data("linked file contents".utf8).write(to: URL(fileURLWithPath: values[3]))
                return RunResult(started: now, ended: Date(), stdout: "", stderr: "", exitCode: 0, failure: nil)
            } catch {
                return RunResult(started: now, ended: Date(), stdout: "", stderr: "Failure", exitCode: 1, failure: .operation)
            }
        }
        let navigating = commands.first?.hasPrefix("cd ") == true
        let failed = navigating && failNavigation
        let now = Date()
        return RunResult(started: now, ended: now, stdout: failed ? "" : """
        Remote working directory: \(navigating ? "/共有/実フォルダ" : "/home/test")
        lrwxrwxrwx 1 u g 9 Jan 1 2024 共有リンク -> /共有/実フォルダ
        """, stderr: failed ? "Not a directory" : "", exitCode: failed ? 1 : 0,
                         failure: failed ? .operation : nil)
    }
}

private actor FolderRunner: SFTPRunning {
    func run(host: String, commands: [String]) async -> RunResult {
        let now = Date()
        if commands.first?.hasPrefix("get -p ") == true {
            let quoted = commands[0].components(separatedBy: "\"")
            do {
                try Data("folder bytes".utf8).write(to: URL(fileURLWithPath: quoted[3]))
            } catch {
                return RunResult(started: now, ended: Date(), stdout: "", stderr: "Failure", exitCode: 1, failure: .operation)
            }
            return RunResult(started: now, ended: Date(), stdout: "", stderr: "", exitCode: 0, failure: nil)
        }
        let inside = commands.first == "cd \"/folder\""
        let stdout = inside ? "Remote working directory: /folder\n-rw-r--r-- 1 u g 12 Nov 10 12:00 file.txt\n" : "Remote working directory: /\ndrwxr-xr-x 1 u g 0 Nov 10 12:00 folder\n"
        return RunResult(started: now, ended: Date(), stdout: stdout, stderr: "", exitCode: 0, failure: nil)
    }
}

private actor FolderLinkRunner: SFTPRunning {
    let directory: Bool
    let runner = FolderRunner()
    init(directory: Bool = true) { self.directory = directory }
    func readLink(host: String, path: String) async -> RunResult {
        RunResult(started: Date(), ended: Date(), stdout: "../missing", stderr: "", exitCode: 0, failure: nil)
    }
    func run(host: String, commands: [String]) async -> RunResult {
        if commands.first == "cd \"/alias\"" {
            if directory { return await runner.run(host: host, commands: ["cd \"/folder\"", "pwd", "ls -la", "bye"]) }
            return RunResult(started: Date(), ended: Date(), stdout: "", stderr: "Not a directory", exitCode: 1, failure: .operation)
        }
        if commands.contains("ls -1a") {
            return RunResult(started: Date(), ended: Date(), stdout: "alias\nfolder\n", stderr: "", exitCode: 0, failure: nil)
        }
        let result = await runner.run(host: host, commands: commands)
        let root = !commands.contains("cd \"/folder\"") && commands.first?.hasPrefix("get ") != true
        return RunResult(started: result.started, ended: result.ended,
                         stdout: result.stdout + (root ? "lrwxrwxrwx 1 u g 7 Nov 10 12:00 alias\n" : ""),
                         stderr: result.stderr, exitCode: result.exitCode, failure: result.failure)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func testRestoresHostAndPanelPreferencesWithoutConnecting() async throws {
        let suite = "OpenSFTP.StartupPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = StubRunner(failDownloads: false)
        let first = AppModel(service: runner, defaults: defaults)
        XCTAssertTrue(first.showFolderStatusBar)
        XCTAssertTrue(first.showStatusBar)
        XCTAssertTrue(first.showConnectionBar)
        XCTAssertEqual(first.hostInput, "")
        first.hostInput = "silver"
        first.showFolderStatusBar = false
        first.showStatusBar = false
        first.showConnectionBar = false
        first.showQueue = false
        first.showLogs = true

        let restored = AppModel(service: runner, defaults: defaults)
        await Task.yield()
        XCTAssertEqual(restored.hostInput, "silver")
        XCTAssertFalse(restored.showFolderStatusBar)
        XCTAssertFalse(restored.showStatusBar)
        XCTAssertTrue(restored.showConnectionBar, "The connection bar must be shown on every launch")
        XCTAssertFalse(restored.showQueue)
        XCTAssertTrue(restored.showLogs)
        XCTAssertFalse(restored.connected)
        XCTAssertFalse(restored.busy)
        XCTAssertEqual(restored.host, "")
        XCTAssertEqual(restored.path, "")
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.jobs.isEmpty)
        let batches = await runner.batches
        XCTAssertTrue(batches.isEmpty, "Restoring a host must not run SFTP")

        restored.showFolderStatusBar = true
        restored.showStatusBar = true
        restored.hostInput = ""
        let cleared = AppModel(service: runner, defaults: defaults)
        XCTAssertTrue(cleared.showFolderStatusBar)
        XCTAssertTrue(cleared.showStatusBar)
        XCTAssertEqual(cleared.hostInput, "")
        XCTAssertFalse(cleared.connected)
    }

    func testLanguageSwitchChangesPresentationWithoutChangingJobOrUserData() {
        let model = AppModel(language: .japanese)
        let local = URL(fileURLWithPath: "/tmp/日本語/完了")
        var job = JobRecord(host: "test", title: "フォルダ受信", target: "/日本語/完了",
                            request: .folder(local, "/日本語/完了", .download))
        job.state = .completed
        job.result = "rsync · 完了：転送11件・スキップ1件・フォルダ作成1件"
        job.stdout = "日本語/file.txt\nNumber of files transferred: 11\n"
        model.jobs = [job]
        XCTAssertEqual(model.localized(job.title), "フォルダ受信")
        model.language = .english
        XCTAssertEqual(model.localized(job.title), "Download Folder")
        XCTAssertTrue(model.localized(job.result).contains("11 transferred"))
        XCTAssertEqual(model.jobs.first?.stdout, job.stdout)
        XCTAssertEqual(model.jobs.first?.target, job.target)
        XCTAssertEqual(model.jobs.first?.result, job.result)
        XCTAssertEqual(model.jobs.first?.id, job.id)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(FolderTransferMethod.allCases.map { model.localized($0.selectionTitle) },
                       ["SFTP: Updated Files Only", "SFTP: Overwrite All", "rsync", "rsync --delete"])
        model.language = .japanese
        XCTAssertEqual(model.localized(job.result), job.result)
        XCTAssertEqual(model.jobs.count, 1)
    }

    private func receiverPasteboard(for source: FolderDragSource, destination: URL) throws -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        do {
            let items = try source.makePasteboardItems()
            guard pasteboard.writeObjects(items) else { throw NSError(domain: "test", code: 1) }
            var carbon: Pasteboard?
            XCTAssertEqual(PasteboardCreate(pasteboard.name.rawValue as CFString, &carbon), noErr)
            let handle = try XCTUnwrap(carbon)
            XCTAssertEqual(PasteboardSetPasteLocation(handle, destination as CFURL), noErr)
            return pasteboard
        } catch {
            pasteboard.releaseGlobally()
            throw error
        }
    }

    func testFolderDragAdvertisesDirectoryPromiseWithModernSessionSource() async throws {
        let entries = DirectoryListing.parse("""
        drwxr-xr-x 1 u g 0 Nov 10 12:00 folder
        -rw-r--r-- 1 u g 1 Nov 10 12:00 file.txt
        """).entries
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let model = AppModel(service: FolderRunner(), chooseFolderMethod: { _ in .sftp })
        model.busy = true
        let source = FolderDragSource(model: model,
                                      drop: FolderDrop(host: "test", remoteDirectory: "/original", entries: entries))
        let pasteboard = try receiverPasteboard(for: source, destination: parent)
        defer { pasteboard.releaseGlobally() }
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.string(forType: FolderDragSource.contentType), UTType.folder.identifier)
        XCTAssertEqual(items.last?.string(forType: FolderDragSource.contentType), UTType(filenameExtension: "txt")?.identifier)
        XCTAssertTrue(model.jobs.isEmpty, "Reading metadata must not start a transfer")
        XCTAssertEqual(FolderDragSource.destinationDirectory(from: pasteboard)?.path, parent.path)
        // Exercise the real data-provider requests made by a receiver after it
        // sets a paste location. Check the returned file URLs and resulting jobs.
        let urls = items.compactMap { item -> URL? in
            guard let value = item.string(forType: FolderDragSource.urlPromiseType) else { return nil }
            return URL(string: value)
        }
        XCTAssertEqual(urls.map(\.path), [parent.appendingPathComponent("folder").path, parent.appendingPathComponent("file.txt").path])
        for _ in 0..<100 {
            if model.jobs.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertEqual(model.jobs.map(\.target).sorted(), ["/original/file.txt", "/original/folder"])
    }

    func testRepeatedFolderDropsUseOriginalNameAndIgnoreDuplicateCallbacks() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let existing = parent.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let entries = DirectoryListing.parse("drwxr-xr-x 1 u g 0 Nov 10 12:00 folder").entries
        let model = AppModel(service: FolderRunner(), chooseFolderMethod: { _ in .sftp })
        model.busy = true
        let snapshot = FolderDrop(host: "original-host", remoteDirectory: "/original", entries: entries)
        let first = FolderDragSource(model: model, drop: snapshot)
        let second = FolderDragSource(model: model, drop: snapshot)
        model.host = "changed-host"; model.path = "/changed"; model.selection = []
        // A fresh request for the same source/index still must not enqueue twice.
        var pasteboards: [NSPasteboard] = []
        defer { pasteboards.forEach { $0.releaseGlobally() } }
        for source in [first, first, second] {
            let pasteboard = try receiverPasteboard(for: source, destination: parent)
            pasteboards.append(pasteboard)
            let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
            let value = try XCTUnwrap(item.string(forType: FolderDragSource.urlPromiseType))
            XCTAssertEqual(URL(string: value)?.path, existing.path)
        }
        for _ in 0..<100 {
            if model.jobs.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.jobs.count, 2)
        for job in model.jobs {
            XCTAssertEqual(job.host, "original-host")
            guard case let .folder(local, remote, direction) = job.request else {
                XCTFail("Expected a recursive folder download"); continue
            }
            XCTAssertEqual(local.path, existing.path)
            XCTAssertEqual(remote, "/original/folder")
            XCTAssertEqual(direction, .download)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("folder 2").path))
    }

    func testFolderDownloadPublishesContentsBeforeCompletingPromise() async throws {
        let model = AppModel(service: FolderRunner(), chooseFolderMethod: { _ in .sftp })
        model.hostInput = "test"; model.connect()
        try await idle(model)
        model.selection = ["folder"]
        XCTAssertTrue(model.canDownload)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("folder")
        var completed = false
        model.download(host: "test", remote: "/folder", to: destination, isDirectory: true) { error in
            XCTAssertNil(error)
            XCTAssertEqual(try? String(contentsOf: destination.appendingPathComponent("file.txt")), "folder bytes")
            completed = true
        }
        try await idle(model)
        XCTAssertTrue(completed)
        XCTAssertEqual(model.jobs.last?.state, .completed)
        XCTAssertEqual(model.jobs.last?.result, "SFTP · 完了：転送1件・スキップ0件・フォルダ作成1件")
    }

    func testFolderMethodCancellationSettlesPromiseWithoutStartingTransfer() async throws {
        var selections = 0
        let model = AppModel(service: FolderRunner(), chooseFolderMethod: { _ in selections += 1; return nil })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var callbacks = 0
        model.download(host: "test", remote: "/folder", to: destination, isDirectory: true) { error in
            XCTAssertTrue(error is CancellationError)
            callbacks += 1
        }
        try await idle(model)
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(model.jobs.last?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.busy)
    }

    func testFolderMethodSelectionRoutesToRsyncAndRecordsItsLog() async throws {
        let rsync = AppRsyncRunner()
        let model = AppModel(service: FolderRunner(), rsync: rsync, chooseFolderMethod: { _ in .rsync })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        var callbacks = 0
        model.download(host: "test", remote: "/folder", to: destination, isDirectory: true) { error in
            XCTAssertNil(error)
            callbacks += 1
        }
        try await idle(model)
        let requests = await rsync.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(model.jobs.last?.state, .completed)
        XCTAssertTrue(model.jobs.last?.result.hasPrefix("rsync · 完了") == true)
        XCTAssertTrue(model.jobs.last?.stdout.contains("rsync statistics") == true)
        let request = try XCTUnwrap(requests.first)
        let output = try XCTUnwrap(model.jobs.last?.stdout)
        XCTAssertTrue(output.contains("$ " + request.commandLine + "\n"))
        let commandRange = try XCTUnwrap(output.range(of: "$ " + request.commandLine))
        let resultRange = try XCTUnwrap(output.range(of: "rsync statistics"))
        XCTAssertLessThan(commandRange.lowerBound, resultRange.lowerBound)
    }

    func testUnifiedFolderChoicesSelectPolicyAndDeletionWithOnePrompt() async throws {
        for method in FolderTransferMethod.allCases {
            let rsync = AppRsyncRunner()
            var selections = 0
            var description = ""
            let model = AppModel(service: FolderRunner(), rsync: rsync, chooseFolderMethod: { text in
                selections += 1; description = text; return method
            })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("file.txt")
            let sftp = method == .sftp || method == .sftpOverwrite
            try Data((sftp ? "newer local!" : "old").utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60 * 86400)], ofItemAtPath: file.path)
            model.download(host: "test", remote: "/folder", to: directory, isDirectory: true, completion: nil)
            try await idle(model)
            XCTAssertEqual(selections, 1)
            XCTAssertEqual(description, "転送方法を選択してください。")
            XCTAssertEqual(model.jobs.last?.state, .completed)
            if sftp {
                XCTAssertEqual(try String(contentsOf: file), method == .sftp ? "newer local!" : "folder bytes")
                let requests = await rsync.requests
                XCTAssertTrue(requests.isEmpty)
            } else {
                let requests = await rsync.requests
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(requests.first?.arguments.contains("--delete"), method == .rsyncDelete)
                XCTAssertTrue(model.jobs.last?.stdout.contains("rsync statistics") == true)
            }
        }
    }

    func testRsyncLogUpdatesWhileRunningAndIsNotDuplicatedOnSuccessOrFailure() async throws {
        for fail in [false, true] {
            let rsync = StreamingAppRsyncRunner(fail: fail)
            let model = AppModel(service: FolderRunner(), rsync: rsync, chooseFolderMethod: { _ in .rsync })
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            model.download(host: "test", remote: "/folder", to: destination, isDirectory: true, completion: nil)
            for _ in 0..<200 {
                if await rsync.ready { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(model.jobs.last?.state, .running)
            XCTAssertTrue(model.jobs.last?.stdout.contains("first.txt\n") == true)
            XCTAssertFalse(model.jobs.last?.stderr.contains("c2VjcmV0") == true)
            await rsync.finish()
            try await idle(model)
            XCTAssertEqual(model.jobs.last?.state, fail ? .failed : .completed)
            XCTAssertEqual(model.jobs.last?.exitCode, fail ? 23 : 0)
            let stdout = try XCTUnwrap(model.jobs.last?.stdout)
            XCTAssertEqual(stdout.components(separatedBy: "first.txt\n").count - 1, 1)
            XCTAssertEqual(stdout.components(separatedBy: "finished\n").count - 1, 1)
            XCTAssertTrue(stdout.contains("$ '/usr/bin/rsync'"))
            XCTAssertFalse(model.jobs.last?.stderr.contains("c2VjcmV0") == true)
        }
    }

    func testSelectedDirectoryLinkFollowsTargetForSFTPAndRsync() async throws {
        for method in [FolderTransferMethod.sftp, .rsync] {
            let runner = FolderLinkRunner(), rsync = AppRsyncRunner()
            var methodSelections = 0
            let model = AppModel(service: runner, rsync: rsync, chooseFolderMethod: { _ in methodSelections += 1; return method })
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let destination = parent.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            model.download(host: "test", remote: "/alias", to: destination, isSymbolicLink: true, completion: nil)
            try await idle(model)
            XCTAssertEqual(model.jobs.last?.state, .completed)
            XCTAssertEqual(methodSelections, 1)
            if method == .sftp {
                XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file.txt")), "folder bytes")
            } else {
                let requests = await rsync.requests
                let request = try XCTUnwrap(requests.first)
                XCTAssertTrue(request.arguments.contains("--rsync-path=cd '/folder' && rsync"))
            }
        }
    }

    func testSelectedDanglingLinkIsCopiedAsLink() async throws {
        let model = AppModel(service: FolderLinkRunner(directory: false), chooseFolderMethod: { _ in
            XCTFail("A dangling link has no folder to transfer"); return nil
        })
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = parent.appendingPathComponent("alias")
        model.download(host: "test", remote: "/alias", to: destination, isSymbolicLink: true, completion: nil)
        try await idle(model)
        XCTAssertEqual(model.jobs.last?.state, .completed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "../missing")
    }

    func testOpeningSymbolicLinkNavigatesAndPreservesListingOnFailure() async throws {
        for fail in [false, true] {
            let runner = LinkRunner(failNavigation: fail)
            let model = AppModel(service: runner, openLocalFile: { _ in
                XCTFail("リンクをダウンロードして開いてはいけません")
            })
            model.hostInput = "test"; model.connect()
            try await idle(model)
            model.selection = ["共有リンク"]
            XCTAssertTrue(model.canDownload)
            XCTAssertFalse(model.canModify)
            model.openSelection()
            try await idle(model)
            let batches = await runner.batches
            XCTAssertEqual(batches, [["pwd", "ls -la", "bye"],
                                    ["cd \"/home/test/共有リンク\"", "pwd", "ls -la", "bye"]])
            XCTAssertEqual(model.path, fail ? "/home/test" : "/共有/実フォルダ")
            XCTAssertEqual(model.jobs.last?.state, fail ? .failed : .completed)
            if fail {
                XCTAssertEqual(model.entries.map(\.name), ["共有リンク"])
                XCTAssertNotNil(model.errorMessage)
            }
        }
    }

    func testOpeningFileLinkDownloadsTargetWithoutTryingToChangeDirectory() async throws {
        let previousAction = AppPreferences.shared.doubleClickAction
        AppPreferences.shared.doubleClickAction = .download
        defer { AppPreferences.shared.doubleClickAction = previousAction }
        for unknown in [false, true] {
            let runner = LinkRunner(failNavigation: false, fileTarget: true, unknownTarget: unknown)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var opened: [URL] = []
            let model = AppModel(service: runner, downloadsDirectory: directory, openLocalFile: { url in
                XCTAssertEqual(try String(contentsOf: url), "linked file contents")
                opened.append(url)
            })
            model.hostInput = "test"; model.connect()
            try await idle(model)
            model.selection = ["共有リンク"]
            model.openSelection()
            try await idle(model)
            XCTAssertEqual(model.path, "/home/test")
            let batches = await runner.batches
            XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("cd ") })
            if unknown {
                XCTAssertEqual(model.jobs.last?.state, .failed)
                XCTAssertTrue(opened.isEmpty)
                XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("get ") })
                XCTAssertTrue(model.errorMessage?.contains("リンク先の種類を確認できません") == true)
            } else {
                XCTAssertEqual(model.jobs.last?.state, .completed)
                XCTAssertEqual(opened, [directory.appendingPathComponent("共有リンク")])
                XCTAssertTrue(batches.flatMap { $0 }.contains { $0.hasPrefix("get ") })
            }
        }
    }

    func testOpeningFileLinkPreviewsResolvedTargetWhenConfigured() async throws {
        let previousAction = AppPreferences.shared.doubleClickAction
        AppPreferences.shared.doubleClickAction = .preview
        defer { AppPreferences.shared.doubleClickAction = previousAction }
        let runner = LinkRunner(failNavigation: false, fileTarget: true)
        let fs = StubRunner(resolvedPaths: ["/home/test/共有リンク": "/shared/actual.txt"])
        let model = AppModel(remoteFileSystem: fs, service: runner, openLocalFile: { _ in
            XCTFail("Previewing a link must not open a downloaded copy")
        })
        defer { model.preview.close() }
        model.hostInput = "test"; model.connect()
        try await idle(model)
        model.selection = ["共有リンク"]
        model.openSelection()
        try await idle(model)
        XCTAssertEqual(model.jobs.last?.state, .completed)
        XCTAssertEqual(model.path, "/home/test")
        XCTAssertTrue(model.preview.isPresented)
        XCTAssertEqual(model.preview.path, "/shared/actual.txt")
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("get ") || $0.hasPrefix("cd ") })
    }

    func testProgressAppearsAfterDelayAndDisappearsAtCompletion() async throws {
        let runner = ProgressRunner()
        let model = AppModel(service: runner)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        model.download(host: "test", remote: "/file", to: destination, completion: nil)
        for _ in 0..<100 {
            if model.jobs.first?.progress != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(model.jobs.first?.progress)
        XCTAssertEqual(model.jobs.first?.showProgress, false)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(model.jobs.first?.showProgress, true)
        await runner.finish()
        try await idle(model)
        XCTAssertEqual(model.jobs.first?.showProgress, false)
        XCTAssertEqual(model.jobs.first?.state, .completed)
    }

    func testInterruptCancelsActiveAndWaitingDownloadsAndCleansStaging() async throws {
        let runner = ProgressRunner()
        let model = AppModel(service: runner)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var callbacks = 0
        for name in ["active", "waiting"] {
            model.download(host: "test", remote: "/" + name, to: directory.appendingPathComponent(name)) { error in
                XCTAssertTrue(error is CancellationError)
                callbacks += 1
            }
        }
        for _ in 0..<100 {
            if await runner.ready { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.jobs.map(\.state), [.running, .waiting])
        model.interrupt()
        model.interrupt() // Repeated clicks must not repeat a promise callback.
        XCTAssertEqual(model.jobs.last?.state, .cancelled)
        XCTAssertEqual(callbacks, 1)
        // Even a runner that returns success after cancellation must not publish.
        await runner.finish()
        try await idle(model)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.jobs.map(\.state), [.cancelled, .cancelled])
        XCTAssertEqual(callbacks, 2)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.jobs.allSatisfy { $0.ended != nil && !$0.showProgress })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])

        model.download(host: "test", remote: "/new", to: directory.appendingPathComponent("new"), completion: nil)
        for _ in 0..<100 {
            if await runner.ready { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await runner.finish()
        try await idle(model)
        XCTAssertEqual(model.jobs.last?.state, .completed)
    }

    func testInterruptBeforeQueueStartsSettlesWaitingPromise() async throws {
        let model = AppModel(service: StubRunner())
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var callbacks = 0
        model.download(host: "test", remote: "/file", to: destination) { error in
            XCTAssertTrue(error is CancellationError)
            callbacks += 1
        }
        model.interrupt()
        try await idle(model)
        XCTAssertEqual(model.jobs.first?.state, .cancelled)
        XCTAssertEqual(callbacks, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFastTransferNeverRevealsProgressAfterCompletion() async throws {
        for fail in [false, true] {
            let runner = ProgressRunner(fail: fail)
            let model = AppModel(service: runner)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            model.download(host: "test", remote: "/file", to: destination, completion: nil)
            for _ in 0..<100 {
                if await runner.ready { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(model.jobs.first?.progress)
            XCTAssertEqual(model.jobs.first?.showProgress, false)
            await runner.finish()
            try await idle(model)
            try await Task.sleep(nanoseconds: 1_100_000_000)
            XCTAssertEqual(model.jobs.first?.showProgress, false)
            XCTAssertEqual(model.jobs.first?.state, fail ? .failed : .completed)
        }
    }
    private func idle(_ model: AppModel) async throws {
        for _ in 0..<300 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("ジョブが終了しませんでした")
    }

    func testHidingFilesRemovesInvisibleSelectionWithoutARequest() async throws {
        let runner = StubRunner()
        let model = AppModel(service: runner)
        let original = model.showHidden
        defer { model.showHidden = original }
        model.hostInput = "test"; model.connect()
        try await idle(model)
        model.showHidden = true
        model.selectAll()
        XCTAssertEqual(model.selection.count, 3)
        model.showHidden = false
        XCTAssertEqual(model.selection, ["visible.txt", "folder"])
        let count = await runner.batches.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(model.canDownload)
        model.selection = ["visible.txt"]
        XCTAssertTrue(model.canDownload)
    }

    func testQueueIsSerialAndContinuesAfterFailure() async throws {
        let runner = StubRunner()
        let model = AppModel(service: runner)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var callbacks = 0
        for name in ["one", "two"] {
            model.download(host: "test", remote: "/" + name, to: directory.appendingPathComponent(name)) { error in
                XCTAssertNotNil(error); callbacks += 1
            }
        }
        try await idle(model)
        XCTAssertEqual(callbacks, 2)
        XCTAssertEqual(model.jobs.map(\.state), [.failed, .failed])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        let maximum = await runner.maximumActive
        XCTAssertEqual(maximum, 1)
    }

    func testCopyNameUsesSmallestAvailablePositiveNumber() {
        for (name, occupied, expected) in [
            ("file.txt", ["file-1.txt", "file-3.txt"], "file-2.txt"),
            ("file.txt", ["file-2.txt"], "file-1.txt"),
            ("file", ["file-1"], "file-2"),
            ("archive.tar.gz", ["archive.tar-1.gz"], "archive.tar-2.gz"),
            ("日本語.txt", [], "日本語-1.txt")
        ] {
            XCTAssertEqual(AppModel.availableCopyName(name, exists: { occupied.contains($0) }), expected)
        }
    }

    func testDownloadConflictChoicesAndFailurePreserveOriginal() async throws {
        for choice in [AppModel.FileConflictChoice.overwrite, .keepBoth] {
            for fail in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let destination = directory.appendingPathComponent("file.txt")
                try Data("original".utf8).write(to: destination)
                try Data("occupied".utf8).write(to: directory.appendingPathComponent("file-1.txt"))
                try Data().write(to: directory.appendingPathComponent("file-3.txt"))
                var prompts = 0
                let model = AppModel(service: StubRunner(failDownloads: fail), chooseFileConflict: { _, name in
                    XCTAssertEqual(name, "file-2.txt")
                    prompts += 1
                    return choice
                })
                model.download(host: "test", remote: "/file.txt", to: destination, completion: nil)
                try await idle(model)
                XCTAssertEqual(prompts, 1)
                XCTAssertEqual(model.jobs.first?.state, fail ? .failed : .completed)
                XCTAssertEqual(try String(contentsOf: destination), !fail && choice == .overwrite ? "" : "original")
                XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent("file-2.txt").path), !fail && choice == .keepBoth)
                XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("file-1.txt")), "occupied")
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".partial") })
                if !fail && choice == .keepBoth {
                    let log = model.jobs[0].stdout
                    XCTAssertTrue(log.contains(LocalDiff.commandLine(original: destination, saved: directory.appendingPathComponent("file-2.txt"))))
                    XCTAssertTrue(log.contains("-original"))
                    XCTAssertTrue(log.contains("[diff exit: 1]"))
                    XCTAssertEqual(model.jobs[0].exitCode, 0)
                    XCTAssertNil(model.errorMessage)
                } else {
                    XCTAssertFalse(model.jobs[0].stdout.contains("[diff exit:"))
                }
            }
        }
    }

    func testUploadConflictChoices() async throws {
        for choice in [AppModel.FileConflictChoice.overwrite, .keepBoth, .cancel] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("visible.txt")
            try Data("upload".utf8).write(to: source)
            let runner = StubRunner(failDownloads: false)
            let model = AppModel(remoteFileSystem: runner, service: runner, chooseFileConflict: { _, name in
                XCTAssertEqual(name, "visible-1.txt")
                return choice
            })
            model.hostInput = "test"; model.connect()
            try await idle(model)
            model.upload([source])
            try await idle(model)
            let batches = await runner.batches
            let puts = batches.flatMap { $0 }.filter { $0.hasPrefix("put ") }
            if choice == .cancel {
                XCTAssertTrue(puts.isEmpty)
                XCTAssertTrue(model.jobs.contains { $0.title == "アップロード" && $0.state == .cancelled })
                XCTAssertNil(model.errorMessage)
            } else {
                XCTAssertEqual(puts.count, 1)
                XCTAssertTrue(puts[0].contains("\"/home/test/.opensftp-"))
                let published = await runner.publishedUploads
                XCTAssertEqual(published, [choice == .keepBoth ? "/home/test/visible-1.txt" : "/home/test/visible.txt"])
            }
        }
    }

    func testCancellingDownloadPreservesAnExistingFile() async throws {
        let runner = StubRunner()
        let model = AppModel(service: runner, chooseFileConflict: { _, _ in .cancel })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("original".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        model.download(host: "test", remote: "/file", to: destination, completion: nil)
        try await idle(model)
        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertEqual(model.jobs.first?.state, .cancelled)
        let count = await runner.batches.count
        XCTAssertEqual(count, 0)
    }

    func testOpeningFileDownloadsBeforeLaunchingOpen() async throws {
        let previousAction = AppPreferences.shared.doubleClickAction
        AppPreferences.shared.doubleClickAction = .download
        defer { AppPreferences.shared.doubleClickAction = previousAction }
        let runner = StubRunner(failDownloads: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var opened: [URL] = []
        let model = AppModel(service: runner, chooseFileConflict: { _, _ in .cancel }, downloadsDirectory: directory, openLocalFile: { url in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            opened.append(url)
        })
        model.hostInput = "test"; model.connect()
        try await idle(model)
        model.selection = ["visible.txt"]
        model.openSelection()
        XCTAssertTrue(opened.isEmpty)
        try await idle(model)
        XCTAssertEqual(opened, [directory.appendingPathComponent("visible.txt")])
        XCTAssertEqual(model.jobs.last?.state, .completed)
        XCTAssertEqual(model.jobs.last?.title, "取得して開く")
        XCTAssertEqual(model.jobs.last?.result, "保存して開きました")
        XCTAssertFalse(model.busy)

        // A second open must preserve the existing download and must not launch it.
        model.openSelection()
        try await idle(model)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(model.jobs.last?.state, .cancelled)
        let batches = await runner.batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.last?.first?.hasPrefix("get \"/home/test/visible.txt\"") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["visible.txt"])
    }

    func testOpeningFileDoesNotLaunchAfterDownloadFailure() async throws {
        let previousAction = AppPreferences.shared.doubleClickAction
        AppPreferences.shared.doubleClickAction = .download
        defer { AppPreferences.shared.doubleClickAction = previousAction }
        let runner = StubRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(service: runner, downloadsDirectory: directory, openLocalFile: { _ in
            XCTFail("転送に失敗したファイルを開いてはいけません")
        })
        model.hostInput = "test"; model.connect()
        try await idle(model)
        model.selection = ["visible.txt"]
        model.openSelection()
        try await idle(model)
        XCTAssertEqual(model.jobs.last?.state, .failed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
