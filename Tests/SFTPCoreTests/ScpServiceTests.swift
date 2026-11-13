import XCTest
@testable import SFTPCore

final class ScpServiceTests: XCTestCase {
    func testProcessDrainsBothPipesAndRetainsExitStatus() async {
        let script = "i=0; while [ $i -lt 30000 ]; do echo output; echo diagnostic >&2; i=$((i+1)); done; exit 7"
        let result = await SSHProcess.run("/bin/sh", ["-c", script])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertNotNil(result.failure)
        XCTAssertGreaterThan(result.stdout.utf8.count, 100_000)
        XCTAssertGreaterThan(result.stderr.utf8.count, 100_000)
    }
    func testCancellationStopsChildAndInheritedPipeWriters() async throws {
        let stopped = expectation(description: "Process group stopped")
        let task = Task {
            let result = await SSHProcess.run("/bin/sh", ["-c", "sleep 30 & wait"])
            XCTAssertNotEqual(result.exitCode, 0)
            stopped.fulfill()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 3)
    }
}
