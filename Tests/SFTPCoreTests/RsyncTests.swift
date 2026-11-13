import Foundation
import XCTest
@testable import SFTPCore

private actor RecordingRsync: RsyncRunning {
    var requests: [RsyncRequest] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func run(_ request: RsyncRequest) async -> RunResult {
        requests.append(request)
        return RunResult(started: Date(), ended: Date(), stdout: "rsync stats", stderr: fail ? "rsync failed" : "",
                         exitCode: fail ? 23 : 0, failure: fail ? .operation : nil)
    }
}

private actor RsyncChunks {
    var stdout = "", stderr = ""
    func append(_ chunk: RsyncOutputChunk) {
        switch chunk {
        case let .stdout(text): stdout += text
        case let .stderr(text): stderr += text
        }
    }
    var receivedInitialOutput: Bool { stdout.contains("日本語.txt\n") && stderr.contains("diagnostic\n") }
}

@MainActor
final class RsyncTests: XCTestCase {
    func testFolderChoicesHaveRequestedOrderAndSFTPPolicies() {
        XCTAssertEqual(FolderTransferMethod.allCases.map(\.selectionTitle),
                       ["SFTP: 更新分だけ", "SFTP: すべて上書き", "rsync", "rsync --delete"])
        XCTAssertEqual(FolderTransferMethod.choices(destinationExists: true), FolderTransferMethod.allCases)
        XCTAssertEqual(FolderTransferMethod.choices(destinationExists: false).map { $0.selectionTitle(destinationExists: false) },
                       ["SFTP", "rsync"])
        XCTAssertEqual(FolderTransferMethod.sftp.policy, .updatedOnly)
        XCTAssertEqual(FolderTransferMethod.sftpOverwrite.policy, .overwrite)
    }

    func testDeleteRequestUsesWholeTreeAndRejectsRootDestination() throws {
        for direction in [FolderTransferDirection.upload, .download] {
            let request = try RsyncRequest(host: "host", local: URL(fileURLWithPath: "/tmp/tree"), remote: "/remote/tree",
                                           direction: direction, files: [], deleteExtraneous: true)
            XCTAssertTrue(request.arguments.contains("--delete"))
            XCTAssertTrue(request.arguments.contains("--recursive"))
            XCTAssertEqual(Array(request.arguments.prefix(3)), ["-avz", "--8-bit-output", "-e"])
            XCTAssertTrue(request.arguments[3].hasPrefix("/usr/bin/ssh "))
            XCTAssertFalse(request.arguments.contains("--ignore-times"))
            XCTAssertFalse(request.arguments.contains { $0.hasPrefix("--files-from") || $0 == "--from0" })
            XCTAssertTrue(request.input.isEmpty)
        }
        XCTAssertThrowsError(try RsyncRequest(host: "host", local: URL(fileURLWithPath: "/"), remote: "/tree",
                                             direction: .download, files: [], deleteExtraneous: true))
        XCTAssertThrowsError(try RsyncRequest(host: "host", local: URL(fileURLWithPath: "/tmp/tree"), remote: "/",
                                             direction: .upload, files: [], deleteExtraneous: true))
        XCTAssertThrowsError(try RsyncRequest(host: "host", local: URL(fileURLWithPath: "/tmp/tree"), remote: "/tree",
                                             direction: .download, files: ["filtered-file"], deleteExtraneous: true))
    }

    func testDeleteRunsForEmptySourceInBothDirectionsWithoutPolicyPrompt() async throws {
        for direction in [FolderTransferDirection.upload, .download] {
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: local) }
            let runner = TreeRunner(["/remote": .init(.directory), "/remote/tree": .init(.directory)])
            let rsync = RecordingRsync()
            let transfer = FolderTransfer(host: "host", service: runner, rsync: rsync,
                                          choosePolicy: { _ in XCTFail("rsync --delete must not ask for an SFTP policy"); return nil },
                                          skipConflict: { _ in false }, log: { _ in }, status: { _ in })
            _ = try await transfer.run(local: local, remote: "/remote/tree", direction: direction, method: .rsyncDelete) { _ in }
            let requests = await rsync.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(requests.first?.arguments.contains("--delete") == true)
        }
    }

    func testNativeRsyncSummaryUsesOnlyReportedStatistics() {
        let summary = FolderTransferSummary.rsyncStatistics("Number of regular files transferred: 1,234\nNumber of deleted files: 5 (reg: 4, dir: 1)\n")
        XCTAssertEqual(summary.transferred, 1234)
        XCTAssertEqual(summary.deleted, 5)
        XCTAssertNil(summary.skipped)
        XCTAssertNil(summary.directories)
        XCTAssertEqual(summary.description, "完了：転送1234件・削除5件")
        XCTAssertEqual(FolderTransferSummary.rsyncStatistics("").description, "完了（詳細はログを確認）")
    }

    func testLocalRsyncDeleteMirrorsWholeTreeAndHandlesEmptySource() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/rsync") else { throw XCTSkip("Local rsync unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("source"), destination = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("extra-directory"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appendingPathComponent("outside")
        try Data("keep outside".utf8).write(to: outside)
        try Data("new".utf8).write(to: source.appendingPathComponent("kept"))
        try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "kept")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("cycle").path, withDestinationPath: ".")
        try Data("old".utf8).write(to: destination.appendingPathComponent("kept"))
        try Data("extra".utf8).write(to: destination.appendingPathComponent("extra-directory/file"))
        try FileManager.default.createSymbolicLink(atPath: destination.appendingPathComponent("extra-link").path, withDestinationPath: outside.path)
        func execute(delete: Bool) async throws -> RunResult {
            let request = try RsyncRequest(host: "unused", local: destination, remote: "/source", direction: .download,
                                           files: delete ? [] : ["kept", ".hidden", "link", "cycle"], deleteExtraneous: delete)
            // Keep transfer/delete options, but remove the remote transport
            // configuration as well as replacing the operands. Apple's rsync
            // uses --rsync-path for its local receiver too: pin that child to
            // the same executable so PATH cannot select an incompatible rsync.
            let options = request.arguments.enumerated().filter { index, argument in
                argument != "-e" && (index == 0 || request.arguments[index - 1] != "-e")
            }.map(\.element).dropLast(2).filter {
                !$0.hasPrefix("--rsync-path=") && !$0.hasPrefix("--rsh=")
            }
            let arguments = Array(options.dropLast()) + ["--rsync-path=/usr/bin/rsync", "--", source.path + "/", destination.path + "/"]
            XCTAssertTrue(arguments.contains("--rsync-path=/usr/bin/rsync"))
            XCTAssertFalse(arguments.contains { $0.hasPrefix("--rsh=") })
            XCTAssertFalse(arguments.contains("-e"))
            return await RsyncService(executable: "/usr/bin/rsync", arguments: arguments).run(request)
        }
        let merged = try await execute(delete: false)
        XCTAssertTrue(merged.succeeded, merged.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("extra-directory/file").path))
        let mirrored = try await execute(delete: true)
        XCTAssertTrue(mirrored.succeeded, mirrored.stderr)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), ["kept", ".hidden", "link", "cycle"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("cycle").path), ".")
        XCTAssertEqual(try String(contentsOf: outside), "keep outside")
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try FileManager.default.removeItem(at: source.appendingPathComponent(name))
        }
        let emptied = try await execute(delete: true)
        XCTAssertTrue(emptied.succeeded, emptied.stderr)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try String(contentsOf: outside), "keep outside")
    }

    func testLineDecoderRetainsSplitUTF8AndIncompleteLines() {
        var decoder = RsyncLineDecoder()
        let bytes = Data("日本語.txt\npassword=hidden\nlast".utf8)
        var text = ""
        for byte in bytes { text += decoder.consume(Data([byte])) }
        XCTAssertEqual(text, "日本語.txt\npassword=hidden\n")
        XCTAssertEqual(decoder.consume(Data(), finish: true), "last")
        XCTAssertEqual(decoder.consume(Data(), finish: true), "")
    }

    func testProcessStreamsBothOutputsBeforeExitAndKeepsFinalOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = directory.appendingPathComponent("finish")
        let quotedGate = "'" + gate.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        [ -t 1 ] || exit 7
        /bin/cat >/dev/null
        printf '日本語.txt\\n'
        printf 'diagnostic\\n' >&2
        while [ ! -f \(quotedGate) ]; do /bin/sleep 0.05; done
        printf 'finished\\n'
        """
        let runner = RsyncService(executable: "/bin/sh", arguments: ["-c", script])
        let request = try RsyncRequest(host: "host", local: directory, remote: "/root", direction: .download, files: ["日本語.txt"])
        let chunks = RsyncChunks()
        let task = Task { await runner.run(request) { chunk in await chunks.append(chunk) } }
        defer { try? Data().write(to: gate); task.cancel() }
        // Always open the gate, including on assertion failure, so the child
        // cannot remain blocked behind this test.
        for _ in 0..<200 {
            if await chunks.receivedInitialOutput { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let received = await chunks.receivedInitialOutput
        let beforeExit = await chunks.stdout
        XCTAssertTrue(received, "Both streams must be visible while the child is waiting")
        XCTAssertFalse(beforeExit.contains("finished"))
        try Data().write(to: gate)
        let result = await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "日本語.txt\nfinished\n")
        XCTAssertEqual(result.stderr, "diagnostic\n")
        let streamedOut = await chunks.stdout, streamedErr = await chunks.stderr
        XCTAssertEqual(streamedOut, result.stdout)
        XCTAssertEqual(streamedErr, result.stderr)
    }

    func testArgumentsKeepShellCharactersInQuotedRootAndManifest() throws {
        let root = "/remote/日本語 ' $(touch forbidden); [folder]"
        let local = URL(fileURLWithPath: "/tmp/local space")
        let files = ["sub/space name", "#file", ";file", "quote'file", "日本語"]
        for direction in [FolderTransferDirection.upload, .download] {
            let request = try RsyncRequest(host: "user@host", local: local, remote: root, direction: direction, files: files)
            let manifest = request.input.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(manifest, files.sorted().map { "./" + $0 })
            XCTAssertEqual(Array(request.arguments.suffix(2)), direction == .upload
                           ? ["/tmp/local space/", "user@host:./"] : ["user@host:./", "/tmp/local space/"])
            XCTAssertTrue(request.arguments.contains("--rsync-path=cd '/remote/日本語 '\\'' $(touch forbidden); [folder]' && rsync"))
            XCTAssertTrue(request.arguments.contains("--ignore-times"), "The planner has already decided which files to overwrite")
            XCTAssertEqual(Array(request.arguments.prefix(3)), ["-avz", "--8-bit-output", "-e"])
            XCTAssertTrue(request.arguments[3].hasPrefix("/usr/bin/ssh "))
            XCTAssertFalse(request.arguments.contains { $0.hasPrefix("--delete") || $0 == "--inplace" || $0 == "--recursive" })
            XCTAssertTrue(request.arguments.contains { $0.contains("StrictHostKeyChecking=yes") })
            let command = "$ " + request.commandLine + "\n"
            XCTAssertEqual(LogRedactor.redact(command), command)
            let withCredential = command.trimmingCharacters(in: .newlines) + " password=hunter2\n"
            XCTAssertFalse(LogRedactor.redact(withCredential).contains("hunter2"))
        }
    }

    func testRejectsManifestTraversalAndHostOptions() {
        for file in ["../outside", "/absolute", "sub/../outside", "sub/", "sub//file", "bad\nfile", ""] {
            XCTAssertThrowsError(try RsyncRequest(host: "host", local: URL(fileURLWithPath: "/tmp/root"), remote: "/root",
                                                 direction: .upload, files: [file]))
        }
        XCTAssertThrowsError(try RsyncRequest(host: "-option", local: URL(fileURLWithPath: "/tmp/root"), remote: "/root",
                                             direction: .download, files: ["file"]))
    }

    func testRsyncWholeTreeRecursionWithoutDelete() async throws {
        for direction in [FolderTransferDirection.upload, .download] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let local = directory.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = TreeRunner(["/": .init(.directory), "/root": .init(.directory)])
            let rsync = RecordingRsync()
            let transfer = FolderTransfer(host: "host", service: runner, rsync: rsync,
                                          choosePolicy: { _ in XCTFail("rsync must not ask for an SFTP policy"); return nil },
                                          skipConflict: { _ in true }, log: { _ in }, status: { _ in })
            _ = try await transfer.run(local: local, remote: "/root", direction: direction, method: .rsync) { _ in }
            let requests = await rsync.requests
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertTrue(request.arguments.contains("--recursive"))
            XCTAssertFalse(request.arguments.contains("--delete"))
            XCTAssertTrue(request.arguments.contains("-avz"))
            XCTAssertTrue(request.input.isEmpty)
        }
    }

    func testRsyncFailureFailsFolderJobAndKeepsExistingFile() async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("original".utf8).write(to: local.appendingPathComponent("file"))
        let runner = TreeRunner(["/": .init(.directory), "/root": .init(.directory), "/root/file": .init(.file, "new")])
        let transfer = FolderTransfer(host: "host", service: runner, rsync: RecordingRsync(fail: true),
                                      choosePolicy: { _ in .overwrite }, skipConflict: { _ in true }, log: { _ in }, status: { _ in })
        do {
            _ = try await transfer.run(local: local, remote: "/root", direction: .download, method: .rsync) { _ in }
            XCTFail("Expected rsync failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("23")) }
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("file")), "original")
    }

    func testRsyncRequestWithFilesGeneratesManifestAndUsesArguments() throws {
        let targets = ["cycle", "relative", "absolute"]
        let request = try RsyncRequest(host: "host", local: URL(fileURLWithPath: "/tmp/root"),
                                       remote: "/root", direction: .download, files: targets)
        XCTAssertEqual(request.input.split(separator: 0).map { String(decoding: $0, as: UTF8.self) },
                       targets.sorted().map { "./" + $0 })
        XCTAssertTrue(request.arguments.contains("-avz"))
        XCTAssertTrue(request.arguments.contains("--files-from=-"))
        XCTAssertFalse(request.arguments.contains("--recursive"))
    }
}
