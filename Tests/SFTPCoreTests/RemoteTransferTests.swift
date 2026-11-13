import XCTest
@testable import SFTPCore

private actor RemoteTree: RemoteFileSystem, ScpRunning {
    struct Item {
        var attributes: RemoteAttributes
        var contents = Data()
        var link: String?
    }
    var items: [RemoteEndpoint: Item] = [:]
    var events: [String] = []
    var requests: [ScpRequest] = []
    var failScp = false
    var failRename = false
    var failCreate = false
    func rejectCreation() { failCreate = true }
    var changeSourceDuringScp = false
    var sourceParentLinkDuringScp = false
    func configure(failScp: Bool = false, failRename: Bool = false, changeSource: Bool = false, parentLink: Bool = false) {
        self.failScp = failScp; self.failRename = failRename
        changeSourceDuringScp = changeSource; sourceParentLinkDuringScp = parentLink
    }
    func directory(_ host: String, _ path: String) {
        items[RemoteEndpoint(host: host, path: path)] = Item(attributes: RemoteAttributes(size: 0, permissions: 0o040755, modified: 100))
    }
    func file(_ host: String, _ path: String, _ text: String, modified: UInt32 = 100) {
        let data = Data(text.utf8)
        items[RemoteEndpoint(host: host, path: path)] = Item(attributes: RemoteAttributes(size: UInt64(data.count), permissions: 0o100644, modified: modified), contents: data)
    }
    func link(_ host: String, _ path: String, target: String) {
        items[RemoteEndpoint(host: host, path: path)] = Item(attributes: RemoteAttributes(size: UInt64(target.utf8.count), permissions: 0o120777, modified: 100), link: target)
    }
    func contents(_ host: String, _ path: String) -> String? {
        items[RemoteEndpoint(host: host, path: path)].map { String(decoding: $0.contents, as: UTF8.self) }
    }
    func target(_ host: String, _ path: String) -> String? { items[RemoteEndpoint(host: host, path: path)]?.link }
    var temporaries: [RemoteEndpoint] { items.keys.filter { $0.name.hasPrefix(".opensftp-") } }
    func attributes(_ e: RemoteEndpoint, followLink: Bool) async throws -> RemoteAttributes? {
        if followLink, let link = items[e]?.link {
            let path = link.hasPrefix("/") ? link : (e.parent.path as NSString).appendingPathComponent(link)
            return items[RemoteEndpoint(host: e.host, path: (path as NSString).standardizingPath)]?.attributes
        }
        return items[e]?.attributes
    }
    func list(_ e: RemoteEndpoint) async throws -> [RemoteNode] {
        events.append("list \(e.description)")
        guard items[e]?.attributes.kind == .directory else { throw RemoteTransferError("not a directory") }
        return items.filter { $0.key.host == e.host && $0.key != e && $0.key.parent == e }
            .map { RemoteNode(name: $0.key.name, attributes: $0.value.attributes) }
    }
    func realPath(_ e: RemoteEndpoint) async throws -> String {
        if let link = items[e]?.link {
            let path = link.hasPrefix("/") ? link : (e.parent.path as NSString).appendingPathComponent(link)
            return (path as NSString).standardizingPath
        }
        return e.path
    }
    func readLink(_ e: RemoteEndpoint) async throws -> String {
        guard let target = items[e]?.link else { throw RemoteTransferError("not a link") }
        return target
    }
    func createDirectory(_ e: RemoteEndpoint) async throws {
        guard items[e] == nil else { throw RemoteTransferError("exists") }
        events.append("mkdir \(e.description)")
        items[e] = Item(attributes: RemoteAttributes(size: 0, permissions: 0o040700, modified: 100))
    }
    func createFile(_ e: RemoteEndpoint) async throws {
        guard !failCreate, items[e] == nil else { throw RemoteTransferError("exists") }
        events.append("create \(e.description)")
        items[e] = Item(attributes: RemoteAttributes(size: 0, permissions: 0o100600, modified: 100))
    }
    func setAttributes(_ e: RemoteEndpoint, attributes: RemoteAttributes) async throws {
        guard var item = items[e] else { throw RemoteTransferError("missing") }
        // SETSTAT changes permission bits, not the inode's file type. Model
        // chmod semantics so a regular temporary remains removable after chmod.
        let permissions = attributes.permissions.map { ((item.attributes.permissions ?? 0) & 0o170000) | ($0 & 0o7777) }
        item.attributes = RemoteAttributes(size: item.attributes.size, permissions: permissions ?? item.attributes.permissions,
                                           accessed: attributes.accessed ?? item.attributes.accessed,
                                           modified: attributes.modified ?? item.attributes.modified)
        items[e] = item
    }
    func createLink(_ e: RemoteEndpoint, target: String) async throws {
        guard items[e] == nil else { throw RemoteTransferError("exists") }
        events.append("link \(e.description)")
        link(e.host, e.path, target: target)
    }
    func rename(_ e: RemoteEndpoint, to destination: RemoteEndpoint, overwrite: Bool) async throws {
        if failRename { throw RemoteTransferError("atomic replacement unavailable") }
        guard let item = items[e], overwrite || items[destination] == nil else { throw RemoteTransferError("exists") }
        events.append("rename \(destination.description)")
        items[destination] = item
        items.removeValue(forKey: e)
    }
    func remove(_ e: RemoteEndpoint) async throws {
        events.append("remove \(e.description)")
        items.removeValue(forKey: e)
    }
    func run(_ request: ScpRequest) async -> RunResult {
        requests.append(request)
        events.append("scp \(request.source.description)")
        let now = Date()
        if failScp { return RunResult(started: now, ended: now, stdout: "", stderr: "disconnected", exitCode: 255, failure: .network) }
        guard let source = items[request.source], source.attributes.kind == .file else {
            return RunResult(started: now, ended: now, stdout: "", stderr: "missing", exitCode: 1, failure: .operation)
        }
        items[request.destination] = Item(attributes: RemoteAttributes(size: UInt64(source.contents.count), permissions: 0o100600, modified: 100), contents: source.contents)
        if changeSourceDuringScp { file(request.source.host, request.source.path, "changed", modified: 200) }
        if sourceParentLinkDuringScp { link(request.source.host, request.source.parent.path, target: "/elsewhere") }
        return RunResult(started: now, ended: now, stdout: "", stderr: "", exitCode: 0, failure: nil)
    }
}

@MainActor
final class RemoteUploadTests: XCTestCase {
    private func fixture() async throws -> (RemoteTree, RemoteUpload, RemoteEndpoint) {
        let tree = RemoteTree()
        for path in ["/", "/shared", "/shared/upload", "/shared/upload/sub"] { await tree.directory("host", path) }
        await tree.file("host", "/shared/upload/sub/file", "original")
        let upload = try await RemoteUpload.prepare(directory: RemoteEndpoint(host: "host", path: "/shared/upload"), fileSystem: tree)
        return (tree, upload, RemoteEndpoint(host: "host", path: "/shared/upload/sub/file"))
    }

    func testPermissionUpdatePreservesFileTypeSizeAndTimestamps() async throws {
        let (tree, _, destination) = try await fixture()
        let original = try await tree.attributes(destination, followLink: false)
        let before = try XCTUnwrap(original)
        try await tree.setAttributes(destination, attributes: RemoteAttributes(permissions: 0o600))
        let updated = try await tree.attributes(destination, followLink: false)
        let after = try XCTUnwrap(updated)
        XCTAssertEqual(after.kind, .file)
        XCTAssertEqual(after.permissions, 0o100600)
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.modified, before.modified)
    }

    func testPublishesOnlyAfterSuccessfulTransferAndRetainsDestinationMode() async throws {
        let (tree, upload, destination) = try await fixture()
        try await upload.upload(to: destination) { temporary in
            XCTAssertNotEqual(temporary, destination)
            let original = await tree.contents(destination.host, destination.path)
            XCTAssertEqual(original, "original")
            await tree.file(temporary.host, temporary.path, "replacement")
        }
        let saved = await tree.contents(destination.host, destination.path)
        let temporaries = await tree.temporaries
        XCTAssertEqual(saved, "replacement")
        XCTAssertTrue(temporaries.isEmpty)
        let attributes = try await tree.attributes(destination, followLink: false)
        XCTAssertEqual(attributes?.permissions, 0o100644)
    }

    func testFailedOrCancelledTransferKeepsOriginalAndCleansTemporary() async throws {
        for cancelled in [false, true] {
            let (tree, upload, destination) = try await fixture()
            do {
                try await upload.upload(to: destination) { temporary in
                    await tree.file(temporary.host, temporary.path, "partial")
                    if cancelled { throw CancellationError() }
                    throw RemoteTransferError("disconnected")
                }
                XCTFail("Expected transfer failure")
            } catch {}
            let original = await tree.contents(destination.host, destination.path)
            let temporaries = await tree.temporaries
            XCTAssertEqual(original, "original")
            XCTAssertTrue(temporaries.isEmpty)
        }
    }

    func testParentOrHigherAncestorSymlinkStopsBeforeAnyWrite() async throws {
        for path in ["/shared/upload/sub", "/shared"] {
            let (tree, upload, destination) = try await fixture()
            await tree.link("host", path, target: "/outside")
            do {
                try await upload.upload(to: destination) { _ in XCTFail("Must not start transfer") }
                XCTFail("Expected parent substitution error")
            } catch {}
            let events = await tree.events
            XCTAssertFalse(events.contains { $0.hasPrefix("create ") || $0.hasPrefix("rename ") })
        }
    }

    func testParentChangedDuringTransferStopsPublicationAndUnsafeCleanup() async throws {
        let (tree, _, destination) = try await fixture()
        var diagnostics = ""
        let guarded = try await RemoteUpload.prepare(directory: RemoteEndpoint(host: "host", path: "/shared/upload"), fileSystem: tree,
                                                     diagnostic: { diagnostics += $0 })
        do {
            try await guarded.upload(to: destination) { temporary in
                await tree.file(temporary.host, temporary.path, "replacement")
                await tree.link("host", destination.parent.path, target: "/outside")
            }
            XCTFail("Expected parent substitution error")
        } catch {}
        let events = await tree.events
        XCTAssertFalse(events.contains { $0.hasPrefix("rename ") || $0.hasPrefix("remove ") })
        XCTAssertTrue(diagnostics.contains("一時項目が残っている可能性"))
    }

    func testDestinationLinkSubstitutionDoesNotPublish() async throws {
        let (tree, upload, destination) = try await fixture()
        await tree.file("host", "/outside", "keep")
        do {
            try await upload.upload(to: destination) { temporary in
                await tree.file(temporary.host, temporary.path, "replacement")
                await tree.link("host", destination.path, target: "/outside")
            }
            XCTFail("Expected destination substitution error")
        } catch {}
        let outside = await tree.contents("host", "/outside")
        let events = await tree.events
        XCTAssertEqual(outside, "keep")
        XCTAssertFalse(events.contains { $0.hasPrefix("rename ") })
    }

    func testExclusiveCreationFailureNeverWritesOrRemovesCollision() async throws {
        let (tree, upload, destination) = try await fixture()
        await tree.rejectCreation()
        do {
            try await upload.upload(to: destination) { _ in XCTFail("Must not write after failed reservation") }
            XCTFail("Expected exclusive creation failure")
        } catch {}
        let events = await tree.events
        XCTAssertFalse(events.contains { $0.hasPrefix("remove ") || $0.hasPrefix("rename ") })
    }

    func testKeepBothDoesNotOverwriteAFileThatAppearedAfterChoosingItsName() async throws {
        let (tree, upload, destination) = try await fixture()
        do {
            try await upload.upload(to: destination, allowOverwrite: false) { _ in XCTFail("Must not overwrite") }
            XCTFail("Expected a destination conflict")
        } catch {}
        let original = await tree.contents(destination.host, destination.path)
        XCTAssertEqual(original, "original")
        let events = await tree.events
        XCTAssertFalse(events.contains { $0.hasPrefix("create ") })
    }

    func testCancelledTaskStillCleansUpItsTemporary() async throws {
        let (tree, upload, destination) = try await fixture()
        let task = Task { @MainActor in
            try await upload.upload(to: destination) { temporary in
                await tree.file(temporary.host, temporary.path, "partial")
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        let original = await tree.contents(destination.host, destination.path)
        let temporaries = await tree.temporaries
        XCTAssertEqual(original, "original")
        XCTAssertTrue(temporaries.isEmpty)
    }

    func testCanonicalSelectionAllowsAnIntentionalDirectoryAlias() async throws {
        let (tree, _, _) = try await fixture()
        await tree.link("host", "/alias", target: "/shared/upload")
        let upload = try await RemoteUpload.prepare(directory: RemoteEndpoint(host: "host", path: "/alias"), fileSystem: tree)
        let destination = try upload.destination(named: "new")
        XCTAssertEqual(destination.path, "/shared/upload/new")
        try await upload.upload(to: destination, allowOverwrite: false) { temporary in
            await tree.file(temporary.host, temporary.path, "new")
        }
        let saved = await tree.contents(destination.host, destination.path)
        XCTAssertEqual(saved, "new")
    }

    func testUnsupportedAtomicReplacementKeepsOriginalAndCleansTemporary() async throws {
        let (tree, upload, destination) = try await fixture()
        await tree.configure(failRename: true)
        do {
            try await upload.upload(to: destination) { temporary in
                await tree.file(temporary.host, temporary.path, "replacement")
            }
            XCTFail("Expected atomic replacement failure")
        } catch {}
        let original = await tree.contents(destination.host, destination.path)
        let temporaries = await tree.temporaries
        XCTAssertEqual(original, "original")
        XCTAssertTrue(temporaries.isEmpty)
    }
}

@MainActor
final class RemoteTransferTests: XCTestCase {
    private func makeTree() async -> RemoteTree {
        let tree = RemoteTree()
        for host in ["a", "b"] { await tree.directory(host, "/") }
        await tree.directory("a", "/src")
        await tree.directory("b", "/dst")
        return tree
    }
    private func makeTransfer(_ tree: RemoteTree, choice: RemoteFileConflictChoice = .overwrite,
                          policy: FolderTransferPolicy? = .overwrite,
                          limits: ResourceLimits? = .default,
                          inspect: @escaping (RemoteFileConflict) -> Void = { _ in }) -> RemoteTransfer {
        RemoteTransfer(fileSystem: tree, scp: tree, limits: limits, chooseFile: { conflict in inspect(conflict); return choice },
                       choosePolicy: { _ in policy }, skipConflict: { _ in true })
    }

    func testKeepBothUsesSmallestGapAndPreservesOriginal() async throws {
        let tree = await makeTree()
        await tree.file("a", "/src/file.txt", "new")
        for name in ["file.txt", "file-1.txt", "file-3.txt"] { await tree.file("b", "/dst/" + name, "old") }
        var prompts = 0
        let transfer = makeTransfer(tree, choice: .keepBoth) { conflict in
            XCTAssertEqual(conflict.alternative, "file-2.txt"); prompts += 1
        }
        let summary = try await transfer.run(source: RemoteEndpoint(host: "a", path: "/src/file.txt"), destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"))
        XCTAssertEqual(summary.transferred, 1)
        XCTAssertEqual(prompts, 1)
        let old = await tree.contents("b", "/dst/file.txt"), new = await tree.contents("b", "/dst/file-2.txt")
        XCTAssertEqual(old, "old"); XCTAssertEqual(new, "new")
        let temporary = await tree.temporaries
        XCTAssertTrue(temporary.isEmpty)
    }

    func testRemoteCopyTraversalLimitStopsBeforeCreatingAnything() async throws {
        let tree = await makeTree()
        await tree.directory("a", "/src/folder")
        await tree.file("a", "/src/folder/one", "one")
        await tree.file("a", "/src/folder/two", "two")
        var limits = ResourceLimits()
        limits.traversalEntries = 2
        do {
            _ = try await makeTransfer(tree, limits: limits).run(source: RemoteEndpoint(host: "a", path: "/src/folder"),
                                                               destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"))
            XCTFail("Expected traversal overflow")
        } catch { XCTAssertTrue(error is ResourceLimitError) }
        let events = await tree.events
        XCTAssertFalse(events.contains { $0.hasPrefix("create ") || $0.hasPrefix("mkdir ") || $0.hasPrefix("scp ") })
    }

    func testFolderPreservesEmptyHiddenCaseDistinctNamesAndLinks() async throws {
        let tree = await makeTree()
        await tree.directory("a", "/src/project")
        await tree.directory("a", "/src/project/empty")
        for name in [".hidden", "A", "a"] { await tree.file("a", "/src/project/" + name, name) }
        await tree.link("a", "/src/project/relative", target: "../other")
        await tree.link("a", "/src/project/dangling", target: "/missing")
        var policies = 0
        let transfer = RemoteTransfer(fileSystem: tree, scp: tree, chooseFile: { _ in XCTFail("No per-file prompts inside a folder"); return .cancel },
            choosePolicy: { _ in policies += 1; return .overwrite }, skipConflict: { _ in false })
        let summary = try await transfer.run(source: RemoteEndpoint(host: "a", path: "/src/project"), destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"))
        XCTAssertEqual(policies, 0)
        XCTAssertEqual(summary.transferred, 5)
        XCTAssertEqual(summary.directories, 2)
        let empty = try await tree.attributes(RemoteEndpoint(host: "b", path: "/dst/project/empty"), followLink: false)
        XCTAssertEqual(empty?.kind, .directory)
        let target = await tree.target("b", "/dst/project/relative")
        XCTAssertEqual(target, "../other")
        let requests = await tree.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { !$0.arguments.contains("-r") && $0.arguments.contains("-3") })
        let events = await tree.events
        let lastSourceList = try XCTUnwrap(events.lastIndex(where: { $0.hasPrefix("list a:") }))
        let firstWrite = try XCTUnwrap(events.firstIndex(where: { $0.hasPrefix("mkdir ") || $0.hasPrefix("create ") }))
        XCTAssertLessThan(lastSourceList, firstWrite)
    }

    func testUpdatedOnlyUsesRemoteSecondsAndNeverDeletesDestinationOnlyFiles() async throws {
        let tree = await makeTree()
        await tree.directory("a", "/src/folder"); await tree.directory("b", "/dst/folder")
        await tree.file("a", "/src/folder/same", "same", modified: 100)
        await tree.file("b", "/dst/folder/same", "same", modified: 100)
        await tree.file("a", "/src/folder/newer", "new", modified: 101)
        await tree.file("b", "/dst/folder/newer", "old", modified: 100)
        await tree.file("b", "/dst/folder/keep", "keep")
        await tree.link("a", "/src/folder/link", target: "same")
        await tree.link("b", "/dst/folder/link", target: "same")
        let summary = try await makeTransfer(tree, policy: .updatedOnly).run(source: RemoteEndpoint(host: "a", path: "/src/folder"), destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"))
        XCTAssertEqual(summary.transferred, 1); XCTAssertEqual(summary.skipped, 2)
        let newer = await tree.contents("b", "/dst/folder/newer"), keep = await tree.contents("b", "/dst/folder/keep")
        XCTAssertEqual(newer, "new"); XCTAssertEqual(keep, "keep")
    }

    func testFailureChangeAndUnsupportedRenamePreserveExistingFileAndCleanup() async throws {
        for failure in 0..<4 {
            let tree = await makeTree()
            await tree.file("a", "/src/file", "new"); await tree.file("b", "/dst/file", "old")
            await tree.configure(failScp: failure == 0, failRename: failure == 1, changeSource: failure == 2, parentLink: failure == 3)
            do {
                _ = try await makeTransfer(tree).run(source: RemoteEndpoint(host: "a", path: "/src/file"), destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"))
                XCTFail("Expected transfer failure")
            } catch {}
            let old = await tree.contents("b", "/dst/file"), temps = await tree.temporaries
            XCTAssertEqual(old, "old"); XCTAssertTrue(temps.isEmpty)
        }
    }

    func testCancellationAndSelfFolderCopyMakeNoWrites() async throws {
        let tree = await makeTree()
        await tree.file("a", "/src/file", "source"); await tree.file("b", "/dst/file", "original")
        do {
            _ = try await makeTransfer(tree, choice: .cancel).run(source: RemoteEndpoint(host: "a", path: "/src/file"), destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        await tree.directory("a", "/src/folder")
        for parent in ["/src", "/src/folder"] {
            do {
                _ = try await makeTransfer(tree).run(source: RemoteEndpoint(host: "a", path: "/src/folder"), destinationDirectory: RemoteEndpoint(host: "a", path: parent))
                XCTFail("Expected overlap rejection")
            } catch {}
        }
        let events = await tree.events
        XCTAssertFalse(events.contains { $0.hasPrefix("create ") || $0.hasPrefix("mkdir ") })
        XCTAssertFalse(RemoteTransfer.overlap("/data/a", "/data/abc"))
    }

    func testSameFileDisablesOverwriteButAllowsNumberedCopy() async throws {
        let tree = await makeTree()
        await tree.file("a", "/src/file.txt", "original")
        var checked = false
        let transfer = makeTransfer(tree, choice: .keepBoth) { conflict in XCTAssertFalse(conflict.canOverwrite); checked = true }
        _ = try await transfer.run(source: RemoteEndpoint(host: "a", path: "/src/file.txt"), destinationDirectory: RemoteEndpoint(host: "a", path: "/src"))
        XCTAssertTrue(checked)
        let saved = await tree.contents("a", "/src/file-1.txt")
        XCTAssertEqual(saved, "original")
    }

    func testEmptyFolderMergeNeverDeletesAndPolicyCancellationMakesNoWrites() async throws {
        let tree = await makeTree()
        await tree.directory("a", "/src/empty"); await tree.directory("b", "/dst/empty")
        await tree.file("b", "/dst/empty/keep", "keep")
        let source = RemoteEndpoint(host: "a", path: "/src/empty"), destination = RemoteEndpoint(host: "b", path: "/dst")
        do {
            _ = try await makeTransfer(tree, policy: nil).run(source: source, destinationDirectory: destination)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let summary = try await makeTransfer(tree, policy: .overwrite).run(source: source, destinationDirectory: destination)
        XCTAssertEqual(summary.transferred, 0)
        let kept = await tree.contents("b", "/dst/empty/keep")
        XCTAssertEqual(kept, "keep")
        let events = await tree.events
        XCTAssertFalse(events.contains { $0.hasPrefix("create ") || $0.hasPrefix("remove ") || $0.hasPrefix("mkdir ") })
    }

    func testSelectedDirectoryLinkFollowsOnlyItsRoot() async throws {
        let tree = await makeTree()
        await tree.directory("a", "/src/real")
        await tree.file("a", "/src/real/file", "content")
        await tree.link("a", "/src/alias", target: "/src/real")
        _ = try await makeTransfer(tree).run(source: RemoteEndpoint(host: "a", path: "/src/alias"),
            destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"), expectedKind: .symbolicLink)
        let saved = await tree.contents("b", "/dst/alias/file")
        XCTAssertEqual(saved, "content")
        let attributes = try await tree.attributes(RemoteEndpoint(host: "b", path: "/dst/alias"), followLink: false)
        XCTAssertEqual(attributes?.kind, .directory)
    }

    func testChangedDragKindAndExcessiveDepthAreRejectedBeforeWrites() async throws {
        let tree = await makeTree()
        await tree.directory("a", "/src/folder")
        do {
            _ = try await makeTransfer(tree).run(source: RemoteEndpoint(host: "a", path: "/src/folder"),
                destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"), expectedKind: .file)
            XCTFail("Expected changed-kind rejection")
        } catch {}
        var path = "/src/folder"
        for _ in 0..<128 { path += "/nested"; await tree.directory("a", path) }
        do {
            _ = try await makeTransfer(tree).run(source: RemoteEndpoint(host: "a", path: "/src/folder"), destinationDirectory: RemoteEndpoint(host: "b", path: "/dst"))
            XCTFail("Expected depth limit")
        } catch {}
        let events = await tree.events
        XCTAssertFalse(events.contains { $0.hasPrefix("create ") || $0.hasPrefix("mkdir ") })
    }

    func testScpSourceGlobEscapingAndLiteralDestination() throws {
        let source = RemoteEndpoint(host: "user@[::1]", path: "/folder/a [1]*?\\' $.txt")
        let destination = RemoteEndpoint(host: "server", path: "/target/a [1]*?\\' $.txt")
        let request = try ScpRequest(source: source, destination: destination)
        XCTAssertEqual(request.arguments.suffix(2).first, "user@[::1]:/folder/a \\[1\\]\\*\\?\\\\' $.txt")
        XCTAssertEqual(request.arguments.last, destination.description)
        XCTAssertTrue(request.arguments.contains("-B"))
        XCTAssertFalse(request.arguments.contains("-O"))
        XCTAssertThrowsError(try ScpRequest(source: RemoteEndpoint(host: "-bad", path: "/file"), destination: destination))
        XCTAssertThrowsError(try ScpRequest(source: RemoteEndpoint(host: "server", path: "/../file"), destination: destination))
    }
}
