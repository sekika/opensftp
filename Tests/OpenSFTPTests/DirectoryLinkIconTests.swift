import XCTest
import SFTPCore
@testable import OpenSFTP

private actor DirectoryLinkRunner: SFTPRunning {
    private var continuation: CheckedContinuation<[String: Bool], Never>?
    private var result: [String: Bool]?
    var inspected: [[String]] = []
    var ready: Bool { continuation != nil }
    func linkIconTargets(host: String, paths: [String]) async -> [String: LinkIconTarget] {
        await directoryLinks(host: host, paths: paths).mapValues {
            LinkIconTarget(isDirectory: $0, path: $0 ? nil : "/shared/document.pdf")
        }
    }
    func directoryLinks(host: String, paths: [String]) async -> [String: Bool] {
        inspected.append(paths)
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        let result = ["/home/folder-link": true, "/home/file-link": false]
        self.result = result
        continuation?.resume(returning: result); continuation = nil
    }
    func run(host: String, commands: [String]) async -> RunResult {
        let next = commands.first == "cd \"/next\""
        let stdout = next ? "Remote working directory: /next\n" : """
        Remote working directory: /home
        lrwxrwxrwx 1 u g 6 Jan 1 2024 folder-link
        lrwxrwxrwx 1 u g 4 Jan 1 2024 file-link
        lrwxrwxrwx 1 u g 7 Jan 1 2024 broken
        """
        return RunResult(started: Date(), ended: Date(), stdout: stdout, stderr: "", exitCode: 0, failure: nil)
    }
}

@MainActor
final class DirectoryLinkIconTests: XCTestCase {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition did not become true")
    }

    func testInspectionUpdatesFolderIconsWithoutChangingLinkKinds() async throws {
        let runner = DirectoryLinkRunner()
        let model = AppModel(service: runner)
        model.hostInput = "test"; model.connect()
        try await waitUntil { await runner.ready }
        XCTAssertFalse(model.busy, "The browser must not wait for icon metadata")
        XCTAssertTrue(model.directoryLinkNames.isEmpty)
        XCTAssertTrue(model.fileLinkTargets.isEmpty)
        await runner.finish()
        try await waitUntil { model.directoryLinkNames == ["folder-link"] }
        XCTAssertEqual(model.fileLinkTargets, ["file-link": "/shared/document.pdf"])
        XCTAssertNotNil(model.fileLinkIcon(for: "file-link"), "Use the PDF target even though the link has no extension")
        XCTAssertNil(model.fileLinkIcon(for: "broken"))
        XCTAssertEqual(model.entries.count, 3)
        XCTAssertTrue(model.entries.allSatisfy { $0.kind == .symbolicLink })
        let requests = await runner.inspected
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(Set(requests[0]), ["/home/folder-link", "/home/file-link", "/home/broken"])
        model.cancelLinkInspection()
    }

    func testLateInspectionCannotChangeIconsAfterNavigation() async throws {
        let runner = DirectoryLinkRunner()
        let model = AppModel(service: runner)
        model.hostInput = "test"; model.connect()
        try await waitUntil { await runner.ready }
        model.load("/next")
        try await waitUntil { !model.busy && model.path == "/next" }
        await runner.finish()
        await Task.yield()
        XCTAssertTrue(model.directoryLinkNames.isEmpty)
        XCTAssertTrue(model.fileLinkTargets.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testExplicitPreviewOfFileLinkUsesTargetRegardlessOfOpenPreference() async throws {
        let previousAction = AppPreferences.shared.doubleClickAction
        AppPreferences.shared.doubleClickAction = .download
        defer { AppPreferences.shared.doubleClickAction = previousAction }
        let runner = DirectoryLinkRunner()
        await runner.finish()
        let model = AppModel(service: runner, openLocalFile: { _ in
            XCTFail("Explicit preview must not download and open a copy")
        })
        defer { model.preview.close(); model.cancelLinkInspection() }
        model.hostInput = "test"; model.connect()
        try await waitUntil { !model.busy && model.fileLinkTargets["file-link"] != nil }
        let jobCount = model.jobs.count
        model.selection = ["file-link"]
        XCTAssertTrue(model.canPreview)
        XCTAssertFalse(model.canOpenInTerminal)
        model.previewSelection()
        XCTAssertTrue(model.preview.isPresented)
        XCTAssertEqual(model.preview.path, "/shared/document.pdf")
        XCTAssertEqual(model.jobs.count, jobCount)
        let selections: [Set<String>] = [["folder-link"], ["broken"], ["file-link", "folder-link"]]
        for selection in selections {
            model.selection = selection
            XCTAssertFalse(model.canPreview)
            XCTAssertEqual(model.preview.path, "")
        }
        model.selection = ["file-link"]
        XCTAssertEqual(model.preview.path, "/shared/document.pdf", "Selection changes in an open preview must follow file links too")
    }
}
