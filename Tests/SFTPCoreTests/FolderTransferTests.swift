import Foundation
import XCTest
@testable import SFTPCore

actor TreeRunner: SFTPRunning {
    struct Node {
        let kind: RemoteEntry.Kind
        let data: Data
        let date: Date
        let permissions: Int
        init(_ kind: RemoteEntry.Kind, _ text: String = "", date: Date = Date().addingTimeInterval(-120), permissions: Int = 0o644) {
            self.kind = kind; self.data = Data(text.utf8); self.date = date
            self.permissions = permissions
        }
    }
    var tree: [String: Node]
    var batches: [[String]] = []
    let failDownload: String?
    let failDelete: String?
    let malformedListingAt: String?
    let replaceDirectoryAfterRemoval: String?
    let replaceDirectoryAfterUploadReservation: String?
    init(_ tree: [String: Node], failDownload: String? = nil, failDelete: String? = nil, malformedListingAt: String? = nil,
         replaceDirectoryAfterRemoval: String? = nil, replaceDirectoryAfterUploadReservation: String? = nil) {
        self.tree = tree; self.failDownload = failDownload
        self.failDelete = failDelete; self.malformedListingAt = malformedListingAt
        self.replaceDirectoryAfterRemoval = replaceDirectoryAfterRemoval
        self.replaceDirectoryAfterUploadReservation = replaceDirectoryAfterUploadReservation
    }
    func readLink(host: String, path: String) async -> RunResult {
        let now = Date()
        let node = tree[path]
        let target = node?.data.isEmpty == false ? String(decoding: node!.data, as: UTF8.self) : "/outside"
        return RunResult(started: now, ended: now, stdout: target, stderr: "",
                         exitCode: node?.kind == .symbolicLink ? 0 : 1,
                         failure: node?.kind == .symbolicLink ? nil : .operation)
    }
    func run(host: String, commands: [String]) async -> RunResult {
        batches.append(commands)
        let now = Date()
        var output = "", directory = "/"
        do {
            for command in commands {
                let words = tokens(command)
                switch words.first {
                case "cd":
                    var destination = words[1]
                    if let node = tree[destination], node.kind == .symbolicLink {
                        let target = String(decoding: node.data, as: UTF8.self)
                        destination = target.hasPrefix("/") ? target : URL(fileURLWithPath: destination).deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
                    }
                    guard tree[destination]?.kind == .directory else { throw NSError(domain: "test", code: 1) }
                    directory = destination
                case "pwd": output += "Remote working directory: \(directory)\n"
                case "ls":
                    if directory == malformedListingAt { output += "unrecognized listing\n"; continue }
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "MMM d HH:mm"
                    for (path, node) in tree.sorted(by: { $0.key < $1.key }) where path != directory && (path as NSString).deletingLastPathComponent == directory {
                        if words.contains("-1a") { output += (path as NSString).lastPathComponent + "\n"; continue }
                        formatter.dateFormat = abs(node.date.timeIntervalSinceNow) > 180 * 86400 ? "MMM d yyyy" : "MMM d HH:mm"
                        let mode = node.kind == .directory ? "drwxr-xr-x" : node.kind == .symbolicLink ? "lrwxrwxrwx" : node.kind == .other ? "prw-r--r--" : "-rw-r--r--"
                        output += "\(mode) 1 u g \(node.data.count) \(formatter.string(from: node.date)) \((path as NSString).lastPathComponent)\(node.kind == .symbolicLink ? " -> /outside" : "")\n"
                    }
                case "mkdir": tree[words[1]] = Node(.directory)
                case "ln":
                    guard words.prefix(3).elementsEqual(["ln", "-s", "--"]), tree[words[4]] == nil else { throw NSError(domain: "test", code: 1) }
                    tree[words[4]] = Node(.symbolicLink, words[3])
                case "rename":
                    guard let node = tree.removeValue(forKey: words[1]) else { throw NSError(domain: "test", code: 1) }
                    tree[words[2]] = node
                case "rm", "rmdir":
                    let path = words[1]
                    guard path != failDelete, let node = tree[path] else { throw NSError(domain: "test", code: 3) }
                    if words[0] == "rmdir" {
                        guard node.kind == .directory, !tree.keys.contains(where: { $0.hasPrefix(path + "/") }) else { throw NSError(domain: "test", code: 4) }
                    } else if node.kind == .directory { throw NSError(domain: "test", code: 5) }
                    tree.removeValue(forKey: path)
                    if let changed = replaceDirectoryAfterRemoval, tree[changed]?.kind == .directory {
                        tree[changed] = Node(.symbolicLink)
                    }
                case "get":
                    let source = words[words.count - 2], destination = words.last!
                    guard let node = tree[source] else { throw NSError(domain: "test", code: 1) }
                    try node.data.write(to: URL(fileURLWithPath: destination))
                    if source == failDownload { throw NSError(domain: "test", code: 2) }
                    try FileManager.default.setAttributes([.modificationDate: node.date], ofItemAtPath: destination)
                    if words.contains("-p") {
                        try FileManager.default.setAttributes([.posixPermissions: node.permissions], ofItemAtPath: destination)
                    }
                case "put":
                    let source = words[words.count - 2], destination = words.last!
                    let text = try String(contentsOfFile: source, encoding: .utf8)
                    let attributes = try FileManager.default.attributesOfItem(atPath: source)
                    tree[destination] = Node(.file, text, date: attributes[.modificationDate] as! Date)
                case "bye": break
                default: throw NSError(domain: "unexpected command", code: 1)
                }
            }
            return RunResult(started: now, ended: Date(), stdout: output, stderr: "", exitCode: 0, failure: nil)
        } catch {
            return RunResult(started: now, ended: Date(), stdout: output, stderr: "Failure", exitCode: 1, failure: .operation)
        }
    }
    private func tokens(_ command: String) -> [String] {
        var values: [String] = [], value = "", quoted = false, escaped = false
        for c in command {
            if escaped { value.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { quoted.toggle() }
            else if c == " " && !quoted {
                if !value.isEmpty { values.append(value); value = "" }
            } else { value.append(c) }
        }
        if !value.isEmpty { values.append(value) }
        return values
    }
}

extension TreeRunner: RemoteFileSystem {
    func attributes(_ e: RemoteEndpoint, followLink: Bool) async throws -> RemoteAttributes? {
        if e.path == "/", tree[e.path] == nil { return RemoteAttributes(permissions: 0o040755) }
        guard let node = tree[e.path] else { return nil }
        let mode: UInt32 = node.kind == .directory ? 0o040755 : node.kind == .symbolicLink ? 0o120777 : 0o100644
        return RemoteAttributes(size: UInt64(node.data.count), permissions: mode)
    }
    func list(_ e: RemoteEndpoint) async throws -> [RemoteNode] {
        var nodes: [RemoteNode] = []
        for path in tree.keys where path != e.path && (path as NSString).deletingLastPathComponent == e.path {
            if let attrs = try await attributes(RemoteEndpoint(host: e.host, path: path), followLink: false) {
                nodes.append(RemoteNode(name: (path as NSString).lastPathComponent, attributes: attrs))
            }
        }
        return nodes
    }
    func realPath(_ e: RemoteEndpoint) async throws -> String { e.path }
    func readLink(_ e: RemoteEndpoint) async throws -> String { String(decoding: tree[e.path]!.data, as: UTF8.self) }
    func createDirectory(_ e: RemoteEndpoint) async throws {
        guard tree[e.path] == nil else { throw RemoteTransferError("exists") }
        tree[e.path] = Node(.directory)
    }
    func createFile(_ e: RemoteEndpoint) async throws {
        guard tree[e.path] == nil else { throw RemoteTransferError("exists") }
        tree[e.path] = Node(.file)
        if let path = replaceDirectoryAfterUploadReservation { tree[path] = Node(.symbolicLink, "/outside") }
    }
    func setAttributes(_ e: RemoteEndpoint, attributes: RemoteAttributes) async throws {}
    func createLink(_ e: RemoteEndpoint, target: String) async throws { tree[e.path] = Node(.symbolicLink, target) }
    func rename(_ e: RemoteEndpoint, to destination: RemoteEndpoint, overwrite: Bool) async throws {
        guard let node = tree[e.path], overwrite || tree[destination.path] == nil else { throw RemoteTransferError("exists") }
        tree[destination.path] = node
        tree.removeValue(forKey: e.path)
    }
    func remove(_ e: RemoteEndpoint) async throws { tree.removeValue(forKey: e.path) }
}

@MainActor
final class FolderTransferTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func transfer(_ runner: TreeRunner, policy: FolderTransferPolicy = .overwrite,
                          skip: Bool = true, limits: ResourceLimits? = .default) -> FolderTransfer {
        FolderTransfer(host: "test", service: runner, fileSystem: runner, limits: limits, choosePolicy: { _ in policy },
                       skipConflict: { _ in skip }, log: { _ in }, status: { _ in })
    }
    private func put(_ text: String, at url: URL, date: Date) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testMethodSelectionUsesDestinationExistenceBeforeWritingInBothDirections() async throws {
        for direction in [FolderTransferDirection.upload, .download] {
            for exists in [false, true] {
                let parent = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: parent) }
                let local = parent.appendingPathComponent("folder")
                if direction == .upload || exists {
                    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
                }
                var tree: [String: TreeRunner.Node] = ["/": .init(.directory)]
                if direction == .download || exists { tree["/folder"] = .init(.directory) }
                let runner = TreeRunner(tree)
                var selections: [Bool] = []
                let transfer = FolderTransfer(host: "test", service: runner, chooseMethod: { found in
                    selections.append(found)
                    return nil
                }, choosePolicy: { _ in XCTFail("Unexpected policy prompt"); return nil },
                   skipConflict: { _ in XCTFail("Unexpected conflict"); return false },
                   log: { _ in }, status: { _ in })
                do {
                    _ = try await transfer.run(local: local, remote: "/folder", direction: direction) { _ in }
                    XCTFail("Expected cancellation")
                } catch is CancellationError {}
                XCTAssertEqual(selections, [exists])
                let batches = await runner.batches
                XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("mkdir ") || $0.hasPrefix("put ") || $0.hasPrefix("get ") })
                XCTAssertEqual(FileManager.default.fileExists(atPath: local.path), direction == .upload || exists)
            }
        }
    }

    func testUpdatePolicyUsesSizeAndMinutePrecisionWithoutOverwritingNewerDestination() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(FolderTransfer.needsTransfer(policy: .updatedOnly, sourceSize: 5, sourceDate: date,
                                                    destinationSize: 5, destinationDate: date.addingTimeInterval(120)))
        XCTAssertFalse(FolderTransfer.needsTransfer(policy: .updatedOnly, sourceSize: 5, sourceDate: date.addingTimeInterval(5),
                                                    destinationSize: 5, destinationDate: date))
        XCTAssertTrue(FolderTransfer.needsTransfer(policy: .updatedOnly, sourceSize: 6, sourceDate: date,
                                                   destinationSize: 5, destinationDate: date.addingTimeInterval(120)))
        XCTAssertTrue(FolderTransfer.needsTransfer(policy: .updatedOnly, sourceSize: 5, sourceDate: date.addingTimeInterval(120),
                                                   destinationSize: 5, destinationDate: date))
        XCTAssertTrue(FolderTransfer.needsTransfer(policy: .updatedOnly, sourceSize: 5, sourceDate: nil,
                                                   destinationSize: 5, destinationDate: date))
        XCTAssertTrue(FolderTransfer.needsTransfer(policy: .overwrite, sourceSize: 5, sourceDate: date,
                                                   destinationSize: 5, destinationDate: date))
    }

    func testDateOnlyComparisonUsesCalendarDayAndStillDetectsSizeChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let formatter = ISO8601DateFormatter()
        let morning = try XCTUnwrap(formatter.date(from: "2021-06-04T00:00:00+09:00"))
        let evening = try XCTUnwrap(formatter.date(from: "2021-06-04T23:59:59+09:00"))
        let nextDay = try XCTUnwrap(formatter.date(from: "2021-06-05T00:00:00+09:00"))
        func needed(_ source: Date?, _ target: Date?, size: Int64 = 5) -> Bool {
            FolderTransfer.needsTransfer(policy: .updatedOnly, sourceSize: size, sourceDate: source,
                                         destinationSize: 5, destinationDate: target, compareByDay: true, calendar: calendar)
        }
        XCTAssertFalse(needed(evening, morning), "Same local day must be skipped even across UTC dates")
        XCTAssertFalse(needed(morning, evening))
        XCTAssertFalse(needed(morning, nextDay), "Keep a newer destination")
        XCTAssertTrue(needed(nextDay, evening), "A new local day must transfer even within one UTC day")
        XCTAssertTrue(needed(evening, morning, size: 6), "Different sizes must transfer on the same day")
        XCTAssertTrue(needed(nil, morning))
        XCTAssertTrue(needed(morning, nil))
        XCTAssertTrue(FolderTransfer.needsTransfer(policy: .overwrite, sourceSize: 5, sourceDate: morning,
                                                   destinationSize: 5, destinationDate: morning, compareByDay: true, calendar: calendar))
    }

    func testOldFilesWithSameDayAndSizeAreSkippedInBothDirections() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2021, month: 6, day: 4, hour: 12)))
        try put("same", at: root.appendingPathComponent("file.pdf"), date: stamp)
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/file.pdf": .init(.file, "same", date: stamp)])
        for direction in [FolderTransferDirection.download, .upload] {
            let summary = try await transfer(runner, policy: .updatedOnly).run(local: root, remote: "/remote/tree", direction: direction) { _ in }
            XCTAssertEqual(summary.transferred, 0)
            XCTAssertEqual(summary.skipped, 1)
        }
        let batches = await runner.batches
        let commands = batches.flatMap { $0 }
        XCTAssertFalse(commands.contains { $0.hasPrefix("get ") || $0.hasPrefix("put ") })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.pdf")), "same")
    }

    func testUploadMergesHiddenAndEmptyFoldersCopiesLinksAndPreservesDestinationOnlyFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-600), recent = Date().addingTimeInterval(-120)
        try put("same", at: root.appendingPathComponent("same"), date: old)
        try put("newer", at: root.appendingPathComponent("changed"), date: recent)
        try put("hidden", at: root.appendingPathComponent(".hidden"), date: recent)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root)
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/same": .init(.file, "same", date: old),
                                 "/remote/tree/changed": .init(.file, "older", date: old),
                                 "/remote/tree/keep": .init(.file, "keep")])
        let summary = try await transfer(runner, policy: .updatedOnly).run(local: root, remote: "/remote/tree", direction: .upload) { _ in }
        let tree = await runner.tree
        XCTAssertEqual(summary.transferred, 3)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.directories, 1)
        XCTAssertEqual(tree["/remote/tree/changed"]?.data, Data("newer".utf8))
        XCTAssertEqual(tree["/remote/tree/keep"]?.data, Data("keep".utf8))
        XCTAssertEqual(tree["/remote/tree/.hidden"]?.data, Data("hidden".utf8))
        XCTAssertEqual(tree["/remote/tree/empty"]?.kind, .directory)
        XCTAssertEqual(tree["/remote/tree/link"]?.kind, .symbolicLink)
        XCTAssertEqual(tree["/remote/tree/link"]?.data, Data(root.path.utf8))
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("rm ") || $0.hasPrefix("rmdir ") })
    }

    func testUploadStopsWhenParentChangesAfterTemporaryReservation() async throws {
        let local = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("replacement".utf8).write(to: local.appendingPathComponent("file"))
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/file": .init(.file, "original")],
                                replaceDirectoryAfterUploadReservation: "/remote/tree")
        do {
            _ = try await transfer(runner).run(local: local, remote: "/remote/tree", direction: .upload) { _ in }
            XCTFail("Expected parent substitution error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("転送計画後に項目が変更"))
        }
        let batches = await runner.batches
        let tree = await runner.tree
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("put ") || $0.hasPrefix("rename ") })
        XCTAssertEqual(tree["/remote/tree/file"]?.data, Data("original".utf8))
    }

    func testTraversalLimitAbortsUploadAndDownloadBeforeAnyMutation() async throws {
        for direction in [FolderTransferDirection.upload, .download] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            var tree: [String: TreeRunner.Node] = ["/remote": .init(.directory), "/remote/tree": .init(.directory)]
            for name in ["first", "second"] {
                if direction == .upload { try Data("local".utf8).write(to: root.appendingPathComponent(name)) }
                else { tree["/remote/tree/" + name] = .init(.file, "remote") }
            }
            let runner = TreeRunner(tree)
            var limits = ResourceLimits()
            limits.traversalEntries = 2
            do {
                _ = try await transfer(runner, limits: limits).run(local: root, remote: "/remote/tree", direction: direction) { _ in }
                XCTFail("Expected traversal overflow")
            } catch { XCTAssertTrue(error is ResourceLimitError) }
            let batches = await runner.batches
            let after = await runner.tree
            XCTAssertEqual(Set(after.keys), Set(tree.keys))
            XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("put ") || $0.hasPrefix("get ") })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, direction == .upload ? 2 : 0)
        }
    }

    func testDeletionTraversalLimitAbortsBeforeRemovingAnyItem() async throws {
        let tree: [String: TreeRunner.Node] = ["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                             "/remote/tree/one": .init(.file), "/remote/tree/two": .init(.file)]
        let runner = TreeRunner(tree)
        var limits = ResourceLimits()
        limits.traversalEntries = 2
        let deletion = RemoteDeletion(host: "test", service: runner, limits: limits, log: { _ in }, status: { _ in })
        do {
            _ = try await deletion.removeFolder(at: "/remote/tree")
            XCTFail("Expected traversal overflow")
        } catch { XCTAssertTrue(error is ResourceLimitError) }
        let after = await runner.tree
        XCTAssertEqual(Set(after.keys), Set(tree.keys))
    }

    func testDownloadOverwritesFilesMergesFoldersAndSkipsTypeConflicts() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: root.appendingPathComponent("file"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("keep"))
        try Data("conflict".utf8).write(to: root.appendingPathComponent("conflict"))
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/file": .init(.file, "replacement"),
                                 "/remote/tree/.hidden": .init(.file, "hidden"),
                                 "/remote/tree/empty": .init(.directory),
                                 "/remote/tree/conflict": .init(.directory),
                                 "/remote/tree/conflict/child": .init(.file, "must not transfer"),
                                 "/remote/tree/link": .init(.symbolicLink)])
        let summary = try await transfer(runner).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
        XCTAssertEqual(summary.transferred, 3)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "replacement")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("keep")), "keep")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("conflict")), "conflict")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link").path), "/outside")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }

    func testDownloadOverwriteRetainsLocalPermissionsAndRemoteTimestamp() async throws {
        for (localMode, remoteMode) in [(0o600, 0o777), (0o755, 0o600)] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("file")
            try Data("original".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: localMode], ofItemAtPath: file.path)
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                     "/remote/tree/file": .init(.file, "replacement", date: stamp, permissions: remoteMode)])
            _ = try await transfer(runner).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, localMode)
            XCTAssertEqual(try String(contentsOf: file), "replacement")
            let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
            XCTAssertEqual(date.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testNewDownloadRetainsRemotePermissionsAndTimestamp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let modes = [0o600, 0o644, 0o755, 0o777]
        var tree: [String: TreeRunner.Node] = ["/remote": .init(.directory), "/remote/tree": .init(.directory)]
        for mode in modes {
            tree["/remote/tree/file-\(mode)"] = .init(.file, "new", date: stamp, permissions: mode)
        }
        _ = try await transfer(TreeRunner(tree)).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
        for mode in modes {
            let file = root.appendingPathComponent("file-\(mode)")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
            XCTAssertEqual(try String(contentsOf: file), "new")
            let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
            XCTAssertEqual(date.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testDownloadUpdatedOnlyKeepsSameAndNewerDestinationAndTransfersChangedSize() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-600), recent = Date().addingTimeInterval(-120)
        try put("same", at: root.appendingPathComponent("same"), date: recent)
        try put("local", at: root.appendingPathComponent("newer-local"), date: recent)
        try put("short", at: root.appendingPathComponent("size"), date: recent)
        try put("older", at: root.appendingPathComponent("newer-source"), date: old)
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/same": .init(.file, "same", date: recent),
                                 "/remote/tree/newer-local": .init(.file, "other", date: old),
                                 "/remote/tree/size": .init(.file, "different size", date: old),
                                 "/remote/tree/newer-source": .init(.file, "newer", date: recent)])
        let summary = try await transfer(runner, policy: .updatedOnly).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
        XCTAssertEqual(summary.transferred, 2)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("newer-local")), "local")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("size")), "different size")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("newer-source")), "newer")
    }

    func testDownloadNeverFollowsDestinationSymlink() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let outside = parent.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file"), withDestinationURL: outside)
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/file": .init(.file, "replacement")])
        let summary = try await transfer(runner).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
        XCTAssertEqual(summary.transferred, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try String(contentsOf: outside), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("file").path), outside.path)
    }

    func testNewDownloadCreatesNestedAndEmptyFolders() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/nested": .init(.directory),
                                 "/remote/tree/nested/empty": .init(.directory),
                                 "/remote/tree/nested/a b 日本語": .init(.file, "bytes")])
        let root = parent.appendingPathComponent("tree")
        let summary = try await transfer(runner).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
        XCTAssertEqual(summary.directories, 3)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("nested/a b 日本語")), "bytes")
    }

    func testFailedDownloadPreservesExistingFileAndCleansPartialFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: root.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("file").path)
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/file": .init(.file, "partial replacement")], failDownload: "/remote/tree/file")
        do {
            _ = try await transfer(runner).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
            XCTFail("Expected download failure")
        } catch { }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "original")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("file").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["file"])
    }

    func testCancelConflictDuringPlanningDoesNotWriteAnything() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: root.appendingPathComponent("z-conflict"))
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/a-new": .init(.file, "new"),
                                 "/remote/tree/z-conflict": .init(.directory)])
        do {
            _ = try await transfer(runner, skip: false).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
            XCTFail("Expected cancellation")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["z-conflict"])
    }

    func testCopiesRelativeDanglingAndDirectoryLinksWithoutTraversingThem() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let local = parent.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let targets = ["relative": "../日本語 folder/missing", "absolute": "/outside", "cycle": ".", "parent": "..", "option": "-target"]
        for (name, target) in targets {
            try FileManager.default.createSymbolicLink(atPath: local.appendingPathComponent(name).path, withDestinationPath: target)
        }
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory)])
        let sent = try await transfer(runner).run(local: local, remote: "/remote/tree", direction: .upload) { _ in }
        XCTAssertEqual(sent.transferred, targets.count)
        let tree = await runner.tree
        for (name, target) in targets {
            XCTAssertEqual(tree["/remote/tree/" + name]?.kind, .symbolicLink)
            XCTAssertEqual(tree["/remote/tree/" + name]?.data, Data(target.utf8))
        }
        let received = parent.appendingPathComponent("received")
        let downloaded = try await transfer(runner).run(local: received, remote: "/remote/tree", direction: .download) { _ in }
        XCTAssertEqual(downloaded.transferred, targets.count)
        for (name, target) in targets {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: received.appendingPathComponent(name).path), target)
        }
        let unchanged = try await transfer(runner, policy: .updatedOnly).run(local: received, remote: "/remote/tree", direction: .download) { _ in }
        XCTAssertEqual(unchanged.transferred, 0)
        XCTAssertEqual(unchanged.skipped, targets.count)
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("get ") || $0.hasPrefix("put ") })
    }

    func testChangedLinkTargetIsReplacedWithoutModifyingReferentsInBothDirections() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: root.appendingPathComponent("outside"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "outside")
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/link": .init(.symbolicLink, "missing")])
        let download = try await transfer(runner, policy: .updatedOnly).run(local: root, remote: "/remote/tree", direction: .download) { _ in }
        XCTAssertEqual(download.transferred, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("outside")), "keep")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "other")
        let upload = try await transfer(runner, policy: .updatedOnly).run(local: root, remote: "/remote/tree", direction: .upload) { _ in }
        XCTAssertEqual(upload.transferred, 2) // link plus destination-only local file
        let tree = await runner.tree
        XCTAssertEqual(tree["/remote/tree/link"]?.data, Data("other".utf8))
    }

    func testExplicitlySelectedFolderLinkIsFollowedInBothDirections() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let real = parent.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: real.appendingPathComponent("file"))
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "real")
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/alias": .init(.symbolicLink, "/remote/real"),
                                 "/remote/real": .init(.directory), "/remote/real/file": .init(.file, "downloaded")])
        let uploaded = try await transfer(runner).run(local: alias, remote: "/remote/copied", direction: .upload) { _ in }
        XCTAssertEqual(uploaded.transferred, 1)
        let tree = await runner.tree
        XCTAssertEqual(tree["/remote/copied"]?.kind, .directory)
        XCTAssertEqual(tree["/remote/copied/file"]?.data, Data("bytes".utf8))
        let destination = parent.appendingPathComponent("downloaded")
        let downloaded = try await transfer(runner).run(local: destination, remote: "/remote/alias", direction: .download) { _ in }
        XCTAssertEqual(downloaded.transferred, 1)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file")), "downloaded")
    }

    func testAncestorChangedToLinkAfterPlanningIsStillRejected() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("tree")
        let nested = root.appendingPathComponent("nested")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("file"))
        let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory),
                                 "/remote/tree/nested": .init(.directory), "/remote/tree/nested/file": .init(.file, "replacement")])
        var substituted = false
        let transfer = FolderTransfer(host: "test", service: runner, choosePolicy: { _ in .overwrite },
                                      skipConflict: { _ in false }, log: { _ in }, status: { message in
            if message == "0/1件 · file", !substituted {
                do {
                    try FileManager.default.moveItem(at: nested, to: parent.appendingPathComponent("original"))
                    try FileManager.default.createSymbolicLink(atPath: nested.path, withDestinationPath: outside.path)
                    substituted = true
                } catch { XCTFail(error.localizedDescription) }
            }
        })
        do {
            _ = try await transfer.run(local: root, remote: "/remote/tree", direction: .download) { _ in }
            XCTFail("A substituted ancestor must stop the transfer")
        } catch { XCTAssertTrue(error.localizedDescription.contains("フォルダの種類が変更")) }
        XCTAssertTrue(substituted)
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("file")), "keep")
        let batches = await runner.batches
        XCTAssertFalse(batches.flatMap { $0 }.contains { $0.hasPrefix("get ") })
    }

    #if os(macOS)
    func testUploadAcceptsBothMacTemporaryDirectoryPathAliases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let shortPath: String
        if root.path.hasPrefix("/private/var/") { shortPath = String(root.path.dropFirst("/private".count)) }
        else if root.path.hasPrefix("/var/") { shortPath = root.path }
        else { throw XCTSkip("Temporary directory does not use a /var alias") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: root.appendingPathComponent("nested/file"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "missing")
        for path in [shortPath, "/private" + shortPath] {
            let runner = TreeRunner(["/remote": .init(.directory)])
            let summary = try await transfer(runner).run(local: URL(fileURLWithPath: path), remote: "/remote/tree", direction: .upload) { _ in }
            XCTAssertEqual(summary.transferred, 2)
            let tree = await runner.tree
            XCTAssertEqual(tree["/remote/tree/nested/file"]?.data, Data("bytes".utf8))
            XCTAssertEqual(tree["/remote/tree/link"]?.data, Data("missing".utf8))
        }
    }
    #endif
}
