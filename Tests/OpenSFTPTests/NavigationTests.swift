import XCTest
import SFTPCore
@testable import OpenSFTP

private actor NavigationRunner: SFTPRunning {
    private var failures = Set<String>()
    func fail(_ directory: String) { failures.insert(directory) }
    func run(host: String, commands: [String]) async -> RunResult {
        let start = Date()
        try? await Task.sleep(nanoseconds: 5_000_000)
        let requested: String
        if let first = commands.first, first.hasPrefix("cd \"") {
            requested = String(first.dropFirst(4).dropLast())
        } else { requested = "/home" }
        let failed = failures.contains(requested)
        // Exercise resolved paths, as when a symbolic link is opened.
        let directory = requested == "/home/link" ? "/actual" : requested
        return RunResult(started: start, ended: Date(),
                         stdout: failed ? "" : "Remote working directory: \(directory)\n",
                         stderr: failed ? "No such file" : "", exitCode: failed ? 1 : 0,
                         failure: failed ? .operation : nil)
    }
}

@MainActor
final class NavigationTests: XCTestCase {
    private func idle(_ model: AppModel) async throws {
        for _ in 0..<300 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Navigation did not complete")
    }
    private func connected(_ runner: NavigationRunner) async throws -> AppModel {
        let model = AppModel(service: runner)
        model.hostInput = "test"; model.connect()
        try await idle(model)
        return model
    }

    func testBackForwardRefreshAndNewBranch() async throws {
        let model = try await connected(NavigationRunner())
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
        model.load("/home/a"); try await idle(model)
        model.load("/home/a/b"); try await idle(model)
        XCTAssertEqual(model.folderHistory, ["/home", "/home/a", "/home/a/b"])
        model.back(); try await idle(model)
        XCTAssertEqual(model.path, "/home/a")
        XCTAssertTrue(model.canGoForward)
        model.refresh(); try await idle(model)
        XCTAssertEqual(model.folderHistory, ["/home", "/home/a", "/home/a/b"])
        XCTAssertTrue(model.canGoForward)
        model.forward(); try await idle(model)
        XCTAssertEqual(model.path, "/home/a/b")
        XCTAssertFalse(model.canGoForward)
        model.back(); try await idle(model)
        model.load("/other"); try await idle(model)
        XCTAssertEqual(model.folderHistory, ["/home", "/home/a", "/other"])
        XCTAssertFalse(model.canGoForward)
        model.load("/other"); try await idle(model)
        XCTAssertEqual(model.folderHistory, ["/home", "/home/a", "/other"])
    }

    func testFailedVisitAndFailedBackPreserveHistory() async throws {
        let runner = NavigationRunner()
        let model = try await connected(runner)
        model.load("/home/a"); try await idle(model)
        model.load("/home/a/b"); try await idle(model)
        model.back(); try await idle(model)
        await runner.fail("/missing")
        model.load("/missing"); try await idle(model)
        XCTAssertEqual(model.path, "/home/a")
        XCTAssertEqual(model.historyIndex, 1)
        XCTAssertTrue(model.canGoForward)
        await runner.fail("/home")
        model.back(); try await idle(model)
        XCTAssertEqual(model.path, "/home/a")
        XCTAssertEqual(model.historyIndex, 1)
        XCTAssertEqual(model.folderHistory, ["/home", "/home/a", "/home/a/b"])
        model.forward(); try await idle(model)
        XCTAssertEqual(model.path, "/home/a/b")
    }

    func testReconnectClearsHistory() async throws {
        let model = try await connected(NavigationRunner())
        model.load("/home/a"); try await idle(model)
        model.hostInput = "other-host"; model.connect()
        XCTAssertTrue(model.folderHistory.isEmpty)
        XCTAssertFalse(model.canGoBack)
        try await idle(model)
        XCTAssertEqual(model.host, "other-host")
        XCTAssertEqual(model.folderHistory, ["/home"])
        XCTAssertEqual(model.historyIndex, 0)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
    }

    func testPendingHistoryRequestCannotBeDuplicatedOrReplacedByRefresh() async throws {
        let model = try await connected(NavigationRunner())
        model.load("/home/a"); try await idle(model)
        let count = model.jobs.count
        model.back()
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
        model.back(); model.forward(); model.refresh()
        XCTAssertEqual(model.jobs.count, count + 1)
        try await idle(model)
        XCTAssertEqual(model.path, "/home")
        XCTAssertTrue(model.canGoForward)
        XCTAssertEqual(model.folderHistory, ["/home", "/home/a"])
    }

    func testOnlyDisplayedListingIsRecordedAndResolvedPathsAreUsed() async throws {
        let model = try await connected(NavigationRunner())
        model.load("/ignored")
        model.load("/home/link")
        try await idle(model)
        XCTAssertEqual(model.folderHistory, ["/home", "/actual"])
        model.parent(); try await idle(model)
        XCTAssertEqual(model.folderHistory, ["/home", "/actual", "/"])
        model.back(); try await idle(model)
        XCTAssertEqual(model.path, "/actual")
    }
}
