import XCTest
import SFTPCore
@testable import OpenSFTP

@MainActor
final class AppWorkspaceTests: XCTestCase {
    private func models() -> (AppWorkspace, AppModel, AppModel) {
        let workspace = AppWorkspace()
        let suite = "OpenSFTP.WorkspaceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let source = AppModel(workspace: workspace, defaults: defaults), destination = AppModel(workspace: workspace, defaults: defaults)
        source.host = "a"; source.path = "/source"
        destination.host = "b"; destination.path = "/destination"
        workspace.register(source); workspace.register(destination)
        return (workspace, source, destination)
    }
    func testRemoteJobIsOwnedByDestinationAndReferencedBySource() {
        let (workspace, source, destination) = models()
        let request = RemoteCopyRequest(sourceWindowID: source.windowID,
            source: RemoteEndpoint(host: "a", path: "/source/file"), destinationDirectory: RemoteEndpoint(host: "b", path: "/destination"))
        var job = JobRecord(host: "b", title: "リモート間コピー", target: "a:/source/file → b:/destination/file", request: .remoteCopy(request))
        job.stdout = "destination log"
        destination.jobs.append(job)
        XCTAssertEqual(source.outgoingJobs.map(\.id), [job.id])
        XCTAssertTrue(source.outgoingJobs[0].stdout.isEmpty)
        XCTAssertEqual(destination.jobs[0].stdout, "destination log")
        XCTAssertTrue(source.hasRelatedWork)
        XCTAssertTrue(workspace.owner(of: job.id) === destination)
        destination.jobs[0].state = .running
        destination.jobs[0].result = "転送中…"
        XCTAssertEqual(source.outgoingJobs[0].state, .running)
        XCTAssertEqual(source.outgoingJobs[0].result, "転送中…")
        destination.jobs[0].state = .completed
        XCTAssertFalse(source.hasRelatedWork)
        XCTAssertEqual(source.outgoingJobs[0].state, .completed)
    }
    func testSourceCanCancelOnlyItsWaitingRemoteJob() {
        let (workspace, source, destination) = models()
        let request = RemoteCopyRequest(sourceWindowID: source.windowID,
            source: RemoteEndpoint(host: "a", path: "/source/file"), destinationDirectory: RemoteEndpoint(host: "b", path: "/destination"))
        let remote = JobRecord(host: "b", title: "リモート間コピー", target: "remote", request: .remoteCopy(request))
        let unrelated = JobRecord(host: "b", title: "mkdir", target: "/other", request: .mutation("mkdir", ["/other"]))
        destination.jobs = [remote, unrelated]
        workspace.interruptOutgoing(from: source)
        XCTAssertEqual(destination.jobs.map(\.state), [.cancelled, .waiting])
        XCTAssertEqual(source.outgoingJobs[0].state, .cancelled)
        XCTAssertFalse(source.hasRelatedWork)
        destination.jobs[1].state = .cancelled
    }
    func testDragSnapshotsSourceAndRejectsUnregisteredOrSelfTokens() throws {
        let (workspace, source, destination) = models()
        source.entries = DirectoryListing.parse("Remote working directory: /source\n-rw-r--r-- 1 u g 1 Jan 1 2024 file.txt\n").entries
        source.selection = ["file.txt"]
        let token = workspace.beginDrag(from: source)
        source.path = "/changed"; source.host = "changed"; source.selection = []
        let snapshot = try XCTUnwrap(workspace.drag(token, to: destination))
        XCTAssertEqual(snapshot.sources, [RemoteEndpoint(host: "a", path: "/source/file.txt")])
        XCTAssertNil(workspace.drag(token, to: source))
        XCTAssertNil(workspace.drag(UUID(), to: destination))
        workspace.unregister(source)
        XCTAssertNil(workspace.drag(token, to: destination))
    }
    func testWindowStateIsIndependentAndLanguageIsShared() {
        let (workspace, source, destination) = models()
        source.showHidden = true
        destination.showHidden = false
        source.path = "/another"
        XCTAssertEqual(destination.path, "/destination")
        XCTAssertTrue(source.showHidden); XCTAssertFalse(destination.showHidden)
        workspace.setLanguage(.english)
        XCTAssertEqual(source.language, .english); XCTAssertEqual(destination.language, .english)
        workspace.setLanguage(.japanese)
        XCTAssertEqual(source.language, .japanese); XCTAssertEqual(destination.language, .japanese)
    }
    func testCancelledSchedulerWaiterDoesNotKeepPermit() async throws {
        let scheduler = OperationScheduler()
        let first = UUID(), second = UUID(), third = UUID()
        try await scheduler.acquire(first)
        let waiting = expectation(description: "Second waiting")
        let waiter = Task { @MainActor in
            waiting.fulfill()
            do { try await scheduler.acquire(second); scheduler.release(second); XCTFail("Cancelled waiter ran") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [waiting], timeout: 1)
        waiter.cancel()
        await waiter.value
        scheduler.release(first)
        try await scheduler.acquire(third)
        scheduler.release(third)
    }
    func testSchedulerRunsWindowsInOrder() async throws {
        let scheduler = OperationScheduler()
        let first = UUID(), second = UUID(), third = UUID()
        try await scheduler.acquire(first)
        var order: [Int] = []
        let a = Task { @MainActor in
            try await scheduler.acquire(second)
            order.append(2)
            scheduler.release(second)
        }
        // Allow the second request to enqueue before the third.
        await Task.yield()
        let b = Task { @MainActor in
            try await scheduler.acquire(third)
            order.append(3)
            scheduler.release(third)
        }
        await Task.yield()
        XCTAssertTrue(order.isEmpty)
        scheduler.release(first)
        try await a.value; try await b.value
        XCTAssertEqual(order, [2, 3])
    }
}
